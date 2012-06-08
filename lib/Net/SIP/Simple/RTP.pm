###########################################################################
# Net::SIP::Simple::RTP
# implements some RTP behaviors
# - media_recv_echo: receive and echo data with optional delay back
#    can save received data
# - media_send_recv: receive and optionally save data. Sends back data
#    from file with optional repeat count
###########################################################################

use strict;
use warnings;

package Net::SIP::Simple::RTP;

use Net::SIP::Util qw(invoke_callback);
use Socket;
use Net::SIP::Debug;
use Time::HiRes 'gettimeofday';


# on MSWin32 non-blocking sockets are not supported from IO::Socket
use constant CAN_NONBLOCKING => $^O ne 'MSWin32';

###########################################################################
# creates function which will initialize Media for echo back
# Args: ($writeto,$delay)
#   $delay: how much packets delay between receive and echo back (default 0)
#     if <0 no ddata will be send back (e.g. recv only)
#   $writeto: where to save received data (default: don't save)
# Returns: [ \&sub,@args ]
###########################################################################
sub media_recv_echo {
	my ($writeto,$delay) = @_;

	my $sub = sub {
		my ($delay,$writeto,$call,$args) = @_;

		my $lsocks = $args->{media_lsocks};
		my $ssocks = $args->{media_ssocks} || $lsocks;
		my $raddr = $args->{media_raddr};
		my $didit = 0;
		for( my $i=0;1;$i++ ) {
			my $sock = $lsocks->[$i] || last;
			$sock = $sock->[0] if UNIVERSAL::isa( $sock,'ARRAY' );
			my $s_sock = $ssocks->[$i] || last;
			$s_sock = $s_sock->[0] if UNIVERSAL::isa( $s_sock,'ARRAY' );

			my $addr = $raddr->[$i];
			$addr = $addr->[0] if ref($addr);

			my @delay_buffer;
			my ($ltstamp,$lseq,$ltdiff); # needed to get diff between to packets in timestamp units for dtmf
			my $echo_back = sub {
				my ($s_sock,$remote,$delay_buffer,$delay,$writeto,$targs,$didit,$sock) = @_;
				{
					my ($buf,$mpt,$seq,$tstamp,$ssrc,$csrc) = 
						_receive_rtp( $sock,$writeto,$targs,$didit )
						or last;
					#DEBUG( "$didit=$$didit" );
					$$didit = 1;

					if ( $ltstamp ) {
						my $tdiff = $tstamp>$ltstamp ? $tstamp - $ltstamp : 0xffffffff - $ltstamp + $tstamp;
						my $sdiff = $seq>$lseq ? $seq-$lseq: 0xffff-$lseq+$seq;
						$ltdiff = $tdiff/$sdiff if $sdiff>0;
					}
					$ltstamp = $tstamp;
					$lseq = $seq;

					# DTMF - get timing from incoming data
					my $timestamp = $tstamp; # take initial timestamp from sender
					if ( $ltdiff and 
						my ($dbuf,$dpt,$drpt) = _handle_dtmf($targs,\$timestamp, $ltdiff )) {
						my $header = pack('CCnNN',
							0b10000000, # Version 2
							$dpt | 0b10000000, # RTP event
							$seq, # take sequence from sender
							$timestamp, 
							0x1234,    # source ID
						);
						DEBUG( 100,"send %d bytes to RTP", length($dbuf));
						while ($drpt-->0) {
							send( $s_sock,$header.$dbuf,0,$remote );
						}
						return; # send DTMF *instead* of echo data
					}
					$ltstamp = $tstamp;
					$lseq = $seq;


					last if $delay<0;
					last if ! $remote; # call on hold ?
					push @$delay_buffer, $buf;
					while ( @$delay_buffer > $delay ) {
						send( $s_sock,shift(@$delay_buffer),0,$remote );
					}
					CAN_NONBLOCKING && redo; # try recv again
				}
			};

			$call->{loop}->addFD( $sock,
				[ $echo_back,$s_sock,$addr,\@delay_buffer,$delay || 0,$writeto,{
					dtmf => $args->{dtmf_events},
				},\$didit ],
				'rtp_echo_back' );
			my $reset_to_blocking = CAN_NONBLOCKING && $s_sock->blocking(0);
			push @{ $call->{ rtp_cleanup }}, [ sub {
				my ($call,$sock,$rb) = @_;
				DEBUG( 100,"rtp_cleanup: remove socket %d",fileno($sock));
				$call->{loop}->delFD( $sock );
				$sock->blocking(1) if $rb;
			}, $call,$sock,$reset_to_blocking ];
		}

		# on RTP inactivity for at least 10 seconds close connection
		my $timer = $call->{dispatcher}->add_timer( 10,
			[ sub {
				my ($call,$didit,$timer) = @_;
				if ( $$didit ) {
					$$didit = 0;
				} else {
					DEBUG(10, "closing call because if inactivity" );
					$call->bye;
					$timer->cancel;
				}
			}, $call,\$didit ],
			10,
			'rtp_inactivity',
		);
		push @{ $call->{ rtp_cleanup }}, [
			sub {
				shift->cancel;
				DEBUG( 100,"cancel RTP timer" );
			},
			$timer
		];
	};

	return [ $sub,$delay,$writeto ];
}

###########################################################################
# creates function which will initialize Media for saving received data
# into file and sending data from another file
# Args: ($readfrom;$repeat,$writeto)
#   $readfrom: where to read data for sending from (filename or callback
#     which returns payload)
#   $repeat: if <= 0 the data in $readfrom will be send again and again
#     if >0 the data in $readfrom will be send $repeat times
#   $writeto: where to save received data (undef == don't save), either
#     filename or callback which gets packet as argument
# Returns: [ \&sub,@args ]
###########################################################################
sub media_send_recv {
	my ($readfrom,$repeat,$writeto) = @_;

	my $sub = sub {
		my ($writeto,$readfrom,$repeat,$call,$args) = @_;

		my $lsocks = $args->{media_lsocks};
		my $ssocks = $args->{media_ssocks} || $lsocks;
		my $raddr = $args->{media_raddr};
		my $didit = 0;
		for( my $i=0;1;$i++ ) {
			my $sock = $lsocks->[$i] || last;
			$sock = $sock->[0] if UNIVERSAL::isa( $sock,'ARRAY' );
			my $s_sock = $ssocks->[$i] || last;
			$s_sock = $s_sock->[0] if UNIVERSAL::isa( $s_sock,'ARRAY' );

			my $addr = $raddr->[$i];
			$addr = $addr->[0] if ref($addr);

			# recv once I get an event on RTP socket
			my $receive = sub {
				my ($writeto,$targs,$didit,$sock) = @_;
				while (1) {
					my $buf = _receive_rtp( $sock,$writeto,$targs,$didit );
					defined($buf) or return;
					CAN_NONBLOCKING or return;
				}
			};
			$call->{loop}->addFD( $sock, [ $receive,$writeto,{},\$didit ],'rtp_receive' );
			my $reset_to_blocking = CAN_NONBLOCKING && $sock->blocking(0);

			# sending need to be done with a timer
			# ! $addr == call on hold
			if ( $addr ) {
				my $cb_done = $args->{cb_rtp_done} || sub { shift->bye };
				my $timer = $call->{dispatcher}->add_timer(
					0, # start immediatly
					[ \&_send_rtp,$s_sock,$call->{loop},$addr,$readfrom, {
						repeat => $repeat || 1,
						cb_done => [ sub { invoke_callback(@_) }, $cb_done, $call ],
						rtp_param => $args->{rtp_param},
						dtmf => $args->{dtmf_events},
					}],
					$args->{rtp_param}[2], # repeat timer
					'rtpsend',
				);

				push @{ $call->{ rtp_cleanup }}, [ sub {
					my ($call,$sock,$timer,$rb) = @_;
					$call->{loop}->delFD( $sock );
					$sock->blocking(1) if $rb;
					$timer->cancel();
				}, $call,$sock,$timer,$reset_to_blocking ];
			}
		}

		# on RTP inactivity for at least 10 seconds close connection
		my $timer = $call->{dispatcher}->add_timer( 10,
			[ sub {
				my ($call,$args,$didit,$timer) = @_;
				if ( $$didit ) {
					$$didit = 0;
				} else {
					DEBUG( 10,"closing call because if inactivity" );
					$call->bye;
					$timer->cancel;
				}
			}, $call,$args,\$didit ],
			10,
			'rtp_inactivity',
		);
		push @{ $call->{ rtp_cleanup }}, [ sub { shift->cancel }, $timer ];
	};

	return [ $sub,$writeto,$readfrom,$repeat ];
}

###########################################################################
# Helper to receive RTP and optionally save it to file
# Args: ($sock,$writeto,$targs,$didit)
#   $sock: RTP socket
#   $writeto: filename for saving or callback which gets packet as argument
#   $targs: \%hash to hold state info between calls of this function
#   $didit: reference to scalar which gets set to TRUE on each received packet
#     and which gets set to FALSE from a timer, thus detecting inactivity
# Return: $packet
#   $packet: received RTP packet (including header)
###########################################################################
sub _receive_rtp {
	my ($sock,$writeto,$targs,$didit) = @_;

	my $from = recv( $sock,my $buf,2**16,0 );
	return if ! $from || !defined($buf) || $buf eq '';
	DEBUG( 50,"received %d bytes from RTP", length($buf));

	if(0) {
		use Socket;
		my ($lport,$laddr) = unpack_sockaddr_in( getsockname($sock));
		$laddr = inet_ntoa( $laddr ).":$lport";
		my ($pport,$paddr) = unpack_sockaddr_in( $from );
		$paddr = inet_ntoa( $paddr ).":$pport";
		DEBUG( "got data on socket %d %s from %s",fileno($sock),$laddr,$paddr );
	}

	$$didit = 1;
	my $packet = $buf;

	my ($vpxcc,$mpt,$seq,$tstamp,$ssrc) = unpack( 'CCnNN',substr( $buf,0,12,'' ));
	my $version = ($vpxcc & 0xc0) >> 6;
	if ( $version != 2 ) {
		DEBUG( 100,"RTP version $version" );
		return
	}
	# skip csrc headers
	my $cc = $vpxcc & 0x0f;
	my $csrc = $cc && substr( $buf,0,4*$cc,'' );

	# skip extension header
	my $xh = $vpxcc & 0x10 ? (unpack( 'nn', substr( $buf,0,4,'' )))[1] : 0;
	substr( $buf,0,4*$xh,'' ) if $xh;

	# ignore padding
	my $padding = $vpxcc & 0x20 ? unpack( 'C', substr($buf,-1,1)) : 0;
	my $payload = $padding ? substr( $buf,0,length($buf)-$padding ): $buf;

	DEBUG( 100,"payload=$seq/%d xh=%d padding=%d cc=%d", length($payload),$xh,$padding,$cc );
	if ( $targs->{rseq} && $seq<= $targs->{rseq}
		&& $targs->{rseq} - $seq < 60000 ) {
		DEBUG( 10,"seq=$seq last=$targs->{rseq} - dropped" );
		return;
	}
	$targs->{rseq} = $seq;

	if ( ref($writeto)) {
		# callback
		invoke_callback( $writeto,$payload,$seq,$tstamp );
	} elsif ( $writeto ) {
		# save into file
		my $fd = $targs->{fdr};
		if ( !$fd ) {
			open( $fd,'>',$writeto ) || die $!;
			$targs->{fdr} = $fd
		}
		syswrite($fd,$payload);
	}

	return wantarray ? ( $packet,$mpt,$seq,$tstamp,$ssrc,$csrc ): $packet;
}

###########################################################################
# Helper to read  RTP data from file (PCMU 8000) and send them through
# the RTP socket
# Args: ($sock,$loop,$addr,$readfrom,$targs,$timer)
#   $sock: RTP socket
#   $loop: event loop (used for looptime for timestamp)
#   $addr: where to send data
#   $readfrom: filename for reading or callback which will return payload
#   $targs: \%hash to hold state info between calls of this function
#     especially 'repeat' holds the number of times this data has to be
#     send (<=0 means forever) and 'cb_done' holds a [\&sub,@arg] callback
#     to end the call after sending all data
#     'repeat' makes only sense if $readfrom is filename
#   $timer: timer which gets canceled once all data are send
# Return: NONE
###########################################################################
sub _send_rtp {
	my ($sock,$loop,$addr,$readfrom,$targs,$timer) = @_;

	$targs->{wseq}++;
	my $seq = $targs->{wseq};

	# 32 bit timestamp based on seq and packet size
	my $timestamp = ( $targs->{rtp_param}[1] * $seq ) % 2**32;

	my ($buf,$payload_type,$repeat) = 
		_handle_dtmf($targs,\$timestamp,$targs->{rtp_param}[1]);
	my $rtp_event = defined($buf) ? 1:0; # DTMF are events
	$repeat ||= 1;

	if ( defined $buf ) {
		# smthg to send already (DTMF)
	} elsif ( ref($readfrom) ) {
		# payload by callback
		$buf = invoke_callback($readfrom,$seq);
		if ( !$buf ) {
			DEBUG( 50, "no more data from callback" );
			$timer && $timer->cancel;
			invoke_callback( $targs->{cb_done} );
			return;
		}
		($buf,$payload_type,$rtp_event,$timestamp) = @$buf if ref($buf);
	} else {
		# read from file
		for(my $tries = 0; $tries<2;$tries++ ) {
			$targs->{wseq} ||= int( rand( 2**16 ));
			my $fd = $targs->{fd};
			if ( !$fd ) {
				$targs->{repeat} = -1 if $targs->{repeat} < 0;
				if ( $targs->{repeat} == 0 ) {
					# no more sending
					DEBUG( 50, "no more data from file" );
					$timer && $timer->cancel;
					invoke_callback( $targs->{cb_done} );
					return;
				}

				open( $fd,'<',$readfrom ) || die $!;
				$targs->{fd} = $fd;
			}
			my $size = $targs->{rtp_param}[1]; # 160 for PCMU/8000
			last if read( $fd,$buf,$size ) == $size;
			# try to reopen file
			close($fd);
			$targs->{fd} = undef;
			$targs->{repeat}--;
		}
	}

	die $! if ! defined $buf or $buf eq '';
	if (0) {
		my ($fp,$fa) = unpack_sockaddr_in( getsockname($sock) );
		$fa = inet_ntoa($fa);
		my ($tp,$ta) = unpack_sockaddr_in( $addr );
		$ta = inet_ntoa($ta);
		DEBUG( 50, "$fa:$fp -> $ta:$tp seq=$seq ts=%x",$timestamp );
	}

	# add RTP header
	$rtp_event = 0 if ! defined $rtp_event;
	$payload_type = $targs->{rtp_param}[0]||0   # 0 == PMCU 8000
		if ! defined $payload_type; 

	my $header = pack('CCnNN',
		0b10000000, # Version 2
		$payload_type | ( $rtp_event << 7 ) ,
		$seq, # sequence
		$timestamp,
		0x1234,    # source ID
	);
	DEBUG( 100,"send %d bytes to RTP", length($buf));
	while ($repeat-->0) {
		send( $sock,$header.$buf,0,$addr ) || die $!;
	}
}

###########################################################################
# Helper to send DTMF
# Args: ($targs,$rtimestamp,$tdiff)
#  $targs: hash which is shared with _send_rtp and other callbacks, contains
#    dtmf array with events 
#  $rtimestamp: reference to timestamp which might get updated with the
#    timestamp which should get send in RTP packet (all packets for same
#    RTP event share timestamp, but increase sequence number)
#  $tdiff: difference between two RTP packets in same unit as timestamp is
# Returns: () | ($buf,$payload_type,$repeat)
#  (): if no DTMF events to handle
#  $buf: RTP payload
#  $payload_type: type for RTP packet
#  $repeat: how often the packet should be send, RTP end events will be send
#     3 times to make sure it gets not lost
###########################################################################
sub _handle_dtmf {
	my ($targs,$rtimestamp,$tdiff) = @_;
	my $dtmfs = $targs->{dtmf};
	DEBUG(100,"got %d dtmfs",0+@{$dtmfs||[]});
	$dtmfs and @$dtmfs or return;

	my ($buf,$payload_type);
	my $repeat = 1; # DTMF ends gets send 3 times to make sure they get received

	while ( @$dtmfs and ! defined $buf ) {
		# we have some DTMF to handle
		# this is an array of hashes with event,volume,duration,callback
		my $dtmf = $dtmfs->[0];

		my $duration = 0;
		if ( my $t = $dtmf->{timestamp} ) {
			$tdiff += $$rtimestamp>$t ? $$rtimestamp-$t : 0xffffffff-$t+$$rtimestamp;
			$duration = 1000 * (gettimeofday - $dtmf->{time});
		} else {
			$dtmf->{timestamp} = $$rtimestamp;
			$dtmf->{time} = gettimeofday;
		}

		my $event = $dtmf->{event};
		my $event_end = ($dtmf->{duration}||0) - $duration <= 0 ? 1:0;

		if ( defined $event ) {
			if ( defined( $payload_type = $dtmf->{rfc2833_type} )) {
				DEBUG(100,"send DTMF event $event duration=$tdiff/duration end=$event_end");
				$repeat = 3 if $event_end;
				$buf = pack('CCn',
					$event,
					($event_end<<7) | ($dtmf->{volume}||10),
					$tdiff,
				);
				# RTP events (DTMF) maintain the timestamp from the initial event packet
				$$rtimestamp = $dtmf->{timestamp};

			} elsif ( defined( $payload_type = $dtmf->{audio_type} )) {
				DEBUG(100,"send DTMF audio $event duration=$tdiff/duration end=$event_end");
				my $cb = $dtmf->{dtmftone} ||= _dtmftone($event);
				$buf = $cb->();

			} else {
				while (my $dtmf = shift(@$dtmfs)) {
					my $cb = $dtmf->{cb_final} or next;
					invoke_callback($cb,'FAIL','neither rfc2833 nor audio are supported by peer');
				}
				return;
			}
		} elsif ( ! $event_end and ! defined($dtmf->{rfc2833_type})
			and defined( $payload_type = $dtmf->{audio_type} )) {
			# add audio for silence
			DEBUG(100,"send DTMF audio silence duration=$tdiff/duration");
			my $cb = $dtmf->{dtmftone} ||= _dtmftone('');
			$buf = $cb->();
		}

		if ( $event_end ) {
			shift(@$dtmfs);
			if ( my $cb = $dtmf->{cb_final} ) {
				invoke_callback($cb,'OK');
			}
		}
	}

	return if ! defined $buf;
	return ($buf,$payload_type,$repeat);
}

###########################################################################
# sub _dtmftone returns a sub to generate audio/silence for DTMF in 
# any duration
# Args: $event
# Returns: $sub for $event
# Comment: the sub should then be called with $sub->(nr_of_samples), e.g.
#  usually $sub->(160). This will generate the payload for the RTP 
#  packet. If $event is no DTMF event it will return a sub which
#  gives silence
#  data returned from the subs are PCMU/8000
###########################################################################

{
	my %event2f = (
		'0' => [ 941,1336 ],
		'1' => [ 697,1209 ],
		'2' => [ 697,1336 ],
		'3' => [ 697,1477 ],
		'4' => [ 770,1209 ],
		'5' => [ 770,1336 ],
		'6' => [ 770,1477 ],
		'7' => [ 852,1209 ],
		'8' => [ 852,1336 ],
		'9' => [ 852,1477 ],
		'*' => [ 941,1209 ], '10' => [ 941,1209 ],
		'#' => [ 941,1477 ], '11' => [ 941,1477 ],
		'A' => [ 697,1633 ], '12' => [ 697,1633 ],
		'B' => [ 770,1633 ], '13' => [ 770,1633 ],
		'C' => [ 852,1633 ], '14' => [ 852,1633 ],
		'D' => [ 941,1633 ], '15' => [ 941,1633 ],
	);

	my $tabsize = 256;
	my $volume  = 100;
	my $speed   = 8000;
	my $samples4pkt = 160;
	my @costab;
	my @ulaw_expandtab;
	my @ulaw_compresstab;

	sub _dtmftone {
		my $event = shift;

		my $f = $event2f{$event};
		if ( ! $f ) {
			# generate silence
			return sub { 
				my $samples = shift || $samples4pkt;
				return pack('C',128) x $samples;
			}
		}

		if (!@costab) {
			for(my $i=0;$i<$tabsize;$i++) {
				$costab[$i] = $volume/100*16383*cos(2*$i*3.14159265358979323846/$tabsize);
			}
			for( my $i=0;$i<128;$i++) {
				$ulaw_expandtab[$i] = int( (256**($i/127) - 1) / 255 * 32767 ); 
			}
			my $j = 0;
			for( my $i=0;$i<32768;$i++ ) {
				$ulaw_compresstab[$i] = $j;
				$j++ if $j<127 and $ulaw_expandtab[$j+1] - $i < $i - $ulaw_expandtab[$j];
			}
		}
		
		my ($f1,$f2) = @$f;
		$f1*= $tabsize;
		$f2*= $tabsize;
		my $d1 = int($f1/$speed);
		my $d2 = int($f2/$speed);
		my $g1 = $f1 % $speed;
		my $g2 = $f2 % $speed;
		my $e1 = int($speed/2);
		my $e2 = int($speed/2);
		my $i1 = my $i2 = 0;

		return sub {
			my $samples = shift || $samples4pkt;
			my $buf = '';
			while ( $samples-- > 0 ) {
				my $val = $costab[$i1]+$costab[$i2];
				my $c = $val>=0 ? 255-$ulaw_compresstab[$val] : 127-$ulaw_compresstab[-$val];
				$buf .= pack('C',$c);

				$e1+= $speed, $i1++ if $e1<0;
				$i1 = ($i1+$d1) % $tabsize;
				$e1-= $g1;

				$e2+= $speed, $i2++ if $e2<0;
				$i2 = ($i2+$d2) % $tabsize;
				$e2-= $g2;
			}
			return $buf;
		}
	}
}

1;
