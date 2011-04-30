#!/usr/bin/perl

=pod 
=head1 
Perl-AMI package 

=item

This class was created for work with Asterisk Manager. It requires NetSDS::Logger, 
Data::Dumper and IO::Socket. 

=cut 

package NetSDS::AMI;

use IO::Socket;
use POSIX;
use bytes;
use Data::Dumper;
use NetSDS::Logger;

my $logger;
my $debug;

BEGIN { }
use Exporter();
@ISA     = qw/Exporter/;
@EXPORT  = qw/AMI/;
$VERSION = 1.0;

=item B<new>

 Constructor creates new object of class AMI, initialize logger  and do nothing more. It may turn on/off debug information of module. 

=cut 

sub new {
	my $this = {
		strerror              => undef,
		socket                => undef,
		safe_manager_host     => undef,
		safe_manager_port     => undef,
		safe_manager_username => undef,
		safe_manager_secret   => undef,
		safe_manager_events   => undef,

	};

	$debug = 0;

	if ( $debug > 0 ) {
		$logger = NetSDS::Logger->new( name => 'NetSDS-AMI' );
	}
	bless($this);
	return $this;
} ## end sub new

=item B<geterror> 

 Method geterror returns last error state in human readable form AKA string

=cut 

sub geterror {
	my $this = shift;
	return $this->{'strerror'};
}

=item B<seterror> 

 Method setserror set error state from first parameter. Do not use it. It's internal/private method of the class. 
 
=cut 

sub seterror {
	my $this = shift;
	$this->{'strerror'} = shift;
}

=item B<connect (host, port, username, secret, events); >

 Connect tries to connect to the Asterisk manager with defined parameters.

=cut 

sub connect {
	my $this = shift;
	my (
		$manager_host,   $manager_port, $manager_username,
		$manager_secret, $manager_events
	  )
	  = @_;

	unless ($manager_host) {
		$this->seterror( sprintf("Missing host address.\n") );
		return undef;
	}
	unless ($manager_port) {
		$this->seterror( sprintf("Missing port. \n") );
		return undef;
	}
	unless ($manager_username) {
		$this->seterror( sprintf("Missing username.\n") );
		return undef;
	}
	unless ($manager_secret) {
		$this->seterror( sprintf("Missing secret.\n") );
		return undef;
	}

	$this->{'safe_manager_host'}     = $manager_host;
	$this->{'safe_manager_port'}     = $manager_port;
	$this->{'safe_manager_username'} = $manager_username;
	$this->{'safe_manager_secret'}   = $manager_secret;
	$this->{'safe_manager_events'}   = $manager_events;

	#   printf( "Connecting to ami://%s:%s@%s:%s\n",
	#       $manager_username, $manager_secret, $manager_host, $manager_port );

	$this->{'socket'} = IO::Socket::INET->new(
		PeerAddr  => $manager_host,
		PeerPort  => $manager_port,
		Proto     => "tcp",
		Timeout   => 30,
		Type      => SOCK_STREAM(),
		ReuseAddr => 1,
	);

	unless ( $this->{'socket'} and $this->{'socket'}->connected ) {
		$this->seterror( sprintf( "Can't connect: %s\n", $! ) );
		return undef;
	}

	$this->{'socket'}->autoflush(1);

	my $reply = $this->read_raw(1);
	unless ( defined($reply) ) {
		return undef;
	}

	# Нет ответа? Значит не туда присоединились.

	if ( $reply =~ m/^(Asterisk Call Manager)\/(\d+\.\d+\w*)/is ) {
		my $manager = $1;
		my $version = $2;
		if ($debug) {
			$logger->log(
				'info',
				sprintf( "Connected. %s/%s\n", $manager, $version )
			);
		}    # Нас устраивает этот ответ

	} else {
		$reply =~ s/[\r\n]+$//;
		if ($debug) {
			$logger->log( 'info', sprintf( "Unknown Protocol. %s\n", $reply ) );
		}
		return undef;
	}

	if ($debug) {
		$logger->log( 'info', sprintf("Sending login message.\n") );
	}

	$login = $this->login( $manager_username, $manager_secret, $manager_events );

	unless ( defined($login) ) {
		return undef;
	}

	return 1;

} ## end sub connect

sub reconnect {
	my $this = shift(@_);

	unless ( $this->{'socket'} and $this->{'socket'}->connected ) {
		my $tries = 0;
		while ( $tries <= 5 ) {

			my $result = $this->connect(
				$this->{'safe_manager_host'},
				$this->{'safe_manager_port'},
				$this->{'safe_manager_username'},
				$this->{'safe_manager_secret'},
				$this->{'safe_manager_events'}
			);
			if ($result) {
				return 1;
			}
			$tries++;
			sleep(1);
		}
	}

} ## end sub reconnect

=item B<sendcommand>

 Example: 
 
 $ami->sendcommand ( Action => 'Status' ); 
 
 Returns undef or count of bytes which sent.
 Use sendcommand to send any commands to Asterisk manager. 
 
=cut

sub sendcommand {
	my $this = shift;

	my (@params) = @_;

	my $text = $this->action_to_text(@params);

	unless ( defined($text) ) {
		return undef;
	}

	if ($debug) {
		$logger->log( 'info', $text );
	}

	my $sent = $this->write_raw($text);

	unless ( defined($sent) ) {
		$this->reconnect();
		$sent = $this->write_raw($text);
		unless ( defined($sent) ) {
			return undef;
		}
	}
	if ($debug) {
		$logger->log( 'info', "sendcommand: sent $sent bytes." );
	}

	return $sent;
} ## end sub sendcommand

=item B<receiveanswer> 


 Example: 

 my $reply = $ami->receiveanswer ( ) ;
 print $reply->{'Response'}; 

 Use receiveanswer to receive any answer from Asterisk manager. 

=cut 

sub receiveanswer {
	my $this = shift;

	my $result = $this->read_raw();

	unless ( defined($result) ) {
		unless ( ( $this->{'socket'} ) and ( $this->{'socket'}->connected ) ) {
			$result = $this->reconnect();
			unless ( defined($result) ) {
				$this->seterror("Socket disconnected.");
				return undef;
			}
		}
		return undef;
	}

	if ($debug) {
		$logger->log( 'info', sprintf( "Received: %s", $result ) );
	}

	$reply = $this->reply_to_hash($result);

	unless ( defined($reply) ) {
		$this->seterror("Reply to hash: error.");
		return undef;
	}

	if ($debug) {
		$logger->log( 'info', sprintf( '%s', Dumper($reply) ) );
	}

	return $reply;
} ## end sub receiveanswer

=item B<read_raw> 

 Method read_raw reads bytes from socket and returns it as result. If any error occured then method returns undef. 

=cut 

sub read_raw {
	my $this = shift;
	my $one  = @_;

	unless ( $this->{'socket'} ) {
		$this->seterror( sprintf("Read from closed socket.\n") );
		return undef;
	}

	unless ( $this->{'socket'}->connected ) {
		$this->seterror( sprintf("Read from disconnected socket.\n") );
		return undef;
	}

	my $data = '';
	while (1) {
		my $line = $this->{'socket'}->getline;
		if ($line) {
			if ($one) {
				$data = $line;
				last;
			} elsif ( $line =~ m/^(?:\r?\n)+/ ) {
				last;
			} else {
				$data .= $line;
			}
		} else {
			if ( defined($line) ) {
				$this->{'socket'} = undef;
				$this->seterror( sprintf( "Unexpected EOF while reading socket: %s\n", $! ) );
				return undef;
			} else {
				$this->{'socket'} = undef;
				$this->seterror( sprintf( "Error while reading socket: %s\n", $! ) );
				return undef;
			}
		}
	}    #### end while(1);
	return $data;
} ## end sub read_raw

=item B<login ( username, secret, events );> 

 Private method. Please use connect(); 

=cut 

sub login {
	my $this = shift;

	my ( $manager_username, $manager_secret, $manager_events ) = @_;

	if ($debug) {
		$logger->log( 'info', sprintf("Loggin in...\n") );
	}

	my $sent = $this->sendcommand(
		Action   => 'Login',
		Username => $manager_username,
		Secret   => $manager_secret,
		Events   => $manager_events,
	);

	unless ( defined($sent) ) {
		return undef;
	}

	$reply = $this->receiveanswer();

	unless ( defined($reply) ) {
		return undef;
	}

	$status = $reply->{'Response'};

	unless ( defined($status) ) {
		$this->seterror( sprintf("Undefined Response.\n") );
		return undef;
	}
	if ( $status eq 'Success' ) {
		if ($debug) {
			$logger->log(
				'info',
				sprintf(
					"Logged in. Server replies: %s\n",
					$reply->{'Message'}
				)
			);
		}
		return 1;
	} elsif ( $status eq 'Error' ) {
		$this->seterror( sprintf( "Error while logging in. %s\n", $reply->{'Message'} ) );
		return undef;
	} else {
		$this->seterror(
			sprintf(
				"Unknown Status. Status: %s, Message: %s\n",
				$status, $reply->{'Message'}
			)
		);
		return undef;
	}
	return undef;
} ## end sub login

=item B<reply_to_hash ( $reply );> 

 Converts array of strings from read_raw() to hashref. 

=cut 

sub reply_to_hash {
	my $this = shift;

	my ($reply) = @_;

	my ( $key, $val );

	my $answer;

	my (@rows) = split( /\r\n/, $reply );

	foreach my $row (@rows) {

		if ($row) {
			if ( $row =~ m/\n/ ) {
				my @arr = split( m/\n/, $row );
				$arr[$#arr] =~ s/--END COMMAND--$//;
				$answer->{'raw'} = $arr;
			} else {
				( $key, $val ) = $row =~ m/^(\w+):\s*(.*)\s*$/;
				$answer->{$key} = $val;
			}
		}
	}
	return $answer;
} ## end sub reply_to_hash

sub command_reply_to_hash {
	my $this = shift;

	my ($reply) = @_;

	my ( $key, $val );

	my $answer;

	my (@rows) = split( /\n/, $reply );

	foreach my $row (@rows) {
		if ($row) {
			if ( $row =~ m/\n/ ) {
				my @arr = split( m/\n/, $row );
				$arr[$#arr] =~ s/--END COMMAND--$//;
				$answer->{'raw'} = $arr;
			} else {
				( $key, $val ) = split( ':', $row );
				$key            = $this->trim($key);
				$val            = $this->trim($val);
				$answer->{$key} = $val;
			}
		}
	}
	return $answer;
} ## end sub command_reply_to_hash

sub trim($) {
	my $this   = shift;
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

=item B<action_to_text> 

 Example: my $text = $ami->action_to_text ( Action => 'Status' );
 
 B<Returns> text of command which already prepared to send to the manager. 

=cut 

sub action_to_text {
	my $this = shift;

	my (@params) = @_;

	my $ret = '';
	my $i   = 0;
	my ( $key, $val );
	while ( $i <= $#params ) {
		$key = $params[ $i++ ];
		$val = $params[ $i++ ];

		if ($key) {
			$ret .= sprintf( "%s: %s%s", $key, $val, "\r\n" );
		} else {
			$ret .= join( "\n", @{$val} );
		}
	}

	return "$ret\r\n";
} ## end sub action_to_text

=item B<write_raw ($data);> 

 Writes data to socket and returns count of sent bytes or undef if error ocuured. 

=cut 

sub write_raw {
	my $this = shift;

	my ($data) = @_;

	unless ( $this->{'socket'} ) {
		$this->seterror( sprintf("Can't write to closed socket.\n") );
		return undef;
	}

	unless ( $this->{'socket'}->connected ) {
		$this->seterror( sprintf("Can't write to disconnected socket.\n") );
		return undef;
	}

	$size = bytes::length($data);

	if ( $this->{'socket'}->print($data) ) {
		unless ( $this->{'socket'}->flush ) {
			$this->seterror( sprintf("Error while flushing socket.\n") );
			return undef;
		}
	} else {
		$this->seterror( sprintf( "Error while writing to socket: %s\n", $! ) );
		return undef;
	}
	return $size;
} ## end sub write_raw

=item B<get_sippeer_by_ipaddr> 

 This method get the list of SIP peers from Asterisk Manager and try to find active SIP peer by 
 IP address and returns SIP Peer Name found by first match or undef if not found. 
 
=cut

sub get_sippeer_by_ipaddr {
	my $this = shift;

	my $ipaddr = shift;

	my @sippeers = $this->SIPpeers();

	unless (@sippeers) {
		$logger->log( 'info', "SIPpeers returns undef" );
		return undef;
	}

	my $i = 0;

	while ( $i <= $#sippeers ) {
		$reply = $sippeers[ $i++ ];
		my $peer_ipaddr = $reply->{'IPaddress'};
		if ($debug) {
			$logger->log(
				'info',
				sprintf( "'%s' vs '%s'", $ipaddr, $peer_ipaddr )
			);
		}
		if ( $peer_ipaddr eq $ipaddr ) {

			# found
			return $reply->{'ObjectName'};
		}
	}
	return undef;

} ## end sub get_sippeer_by_ipaddr

=item B<SIPpeers> 

 This method ask from Asterisk manager the list of SIP peers. 
 Returns array of hash tables that containts information about all SIP Peers 

=cut

sub SIPpeers {
	my $this = shift;

	$text = $this->action_to_text( 'Action' => 'SIPpeers' );

	if ($debug) {
		$logger->log( 'info', sprintf($text) );
	}

	$sent = $this->write_raw($text);

	unless ( defined($sent) ) {
		$logger->log( 'info', 'write_raw returns undef' );
		return undef;
	}

	if ($debug) {
		$logger->log( 'info', sprintf( "Sent %s bytes\n", $sent ) );
	}

	$result = $this->read_raw();

	if ($debug) {
		$logger->log( 'info', sprintf($result) );
	}

	$reply = $this->reply_to_hash($result);
	if ($debug) {
		$logger->log( 'info', sprintf( '%s', Dumper($reply) ) );
	}

	unless ( defined($reply) ) {
		return undef;
	}

	my $status = $reply->{'Response'};

	unless ( defined($status) ) {
		if ($debug) {
			$logger->log( 'info', 'SIPpeers status: ' . $status );
		}
		return undef;
	}

	if ( $status ne 'Success' ) {
		$this->seterror('SIPpeers: Response not success');
		return undef;
	}

	# reading from spcket while did not receive Event: PeerlistComplete

	my @replies;
	while (1) {
		$result = $this->read_raw();
		$reply  = $this->reply_to_hash($result);
		$status = $reply->{'Event'};
		if ($debug) {
			$logger->log( 'info', sprintf( '%s', Dumper($reply) ) );
		}
		if ( $status eq 'PeerlistComplete' ) {
			last;
		}
		push @replies, $reply;
	}
	return @replies;
} ## end sub SIPpeers

=item B<get_calls_by_peername> 

 This method gets status of channels and try to find channels that contains Link: SIP/PeerName. 

=cut

sub get_calls_by_peername {
	my $this = shift;

	my $peername = shift;

	my @liststatus = $this->get_status();

	unless (@liststatus) {
		return undef;
	}

	my $i     = 0;
	my @calls = ();

	while ( $i <= $#liststatus ) {
		my $status = $liststatus[ $i++ ];
		if ($debug) {
			$logger->log( 'info', sprintf( '%s', Dumper($status) ) );
		}

		my $link = $status->{'Link'};

		$link =~ m/SIP\/(\w*)\-(\w*)/is;

		my $pname = $1;

		if ($debug) {
			$logger->log(
				'info',
				sprintf( "'%s' vs '%s'", $peername, $pname )
			);
		}

		if ( $pname eq $peername ) {    # got it
			my $call;
			$call->{'CallerID'} = $status->{'CallerID'};
			$call->{'UniqueID'} = $status->{'Uniqueid'};
			$call->{'Channel'}  = $status->{'Channel'};
			push @calls, $call;
		}
	} ## end while ( $i <= $#liststatus)
	$i = @calls;
	if ($debug) {
		$logger->log( 'info', "Calls amount: " . @calls );
	}
	if ( $i > 0 ) {
		return @calls;
	}
	return undef;
} ## end sub get_calls_by_peername

=item B<get_status>

 This method ask from Asterisk Manager current status of channels and returns it as array of hashrefs; 

=cut

sub get_status {
	my $this = shift;

	my $sent = $this->sendcommand( 'Action' => 'Status' );

	unless ( defined($sent) ) {
		return undef;
	}

	my $reply = $this->receiveanswer();

	unless ( defined($reply) ) {
		return undef;
	}

	my $status = $reply->{'Response'};

	unless ( defined($status) ) {
		return undef;
	}

	if ( $status ne 'Success' ) {
		$this->seterror('Status: Response not success');
		return undef;
	}

	# reading from spcket while did not receive Event: StatusComplete

	my @replies;
	while (1) {
		$reply  = $this->receiveanswer();
		$status = $reply->{'Event'};
		if ( $status eq 'StatusComplete' ) {
			last;
		}
		push @replies, $reply;
	}
	return @replies;
} ## end sub get_status

=item B<get_queue_status> 

 Return status of Queues in the asterisk. 

=cut 

sub get_queue_status {
	my $this = shift;

	my $sent = $this->sendcommand( 'Action' => 'QueueStatus' );

	unless ( defined($sent) ) {
		return undef;
	}

	my $reply = $this->receiveanswer();

	unless ( defined($reply) ) {
		return undef;
	}

	my $status = $reply->{'Response'};

	unless ( defined($status) ) {
		return undef;
	}

	if ( $status ne 'Success' ) {
		$this->seterror('Status: Response not success');
		return undef;
	}

	# reading from spcket while did not receive Event: StatusComplete

	my @replies;
	while (1) {
		$reply  = $this->receiveanswer();
		$status = $reply->{'Event'};
		if ( $status eq 'QueueStatusComplete' ) {
			last;
		}
		push @replies, $reply;
	}
	return @replies;
} ## end sub get_queue_status

=item B<park(channel, timeout)> 

Parks the call. 

=cut 

sub park {
	my $this    = shift;
	my $channel = shift;
	my $timeout = shift;
	my $slot = shift;

	unless ( defined ($slot) ) { 
		$slot = 0; 
	}; 

	my @liststatus = $this->get_status();

	unless (@liststatus) {
		$this->seterror("Not active channels");
		return undef;
	}

	my $i = 0;
	my @calls;

	while ( $i <= $#liststatus ) {
		my $status = $liststatus[ $i++ ];
		if ($debug) {
			$logger->log( 'info', sprintf( '%s', Dumper($status) ) );
		}

		my $chan = $status->{'Channel'};
		if ( $chan ne $channel ) {
			next;
		}

		my $link = $status->{'Link'};

		my $sent = $this->sendcommand(
			'Action'   => 'Park',
			'Channel'  => $channel,
			'Channel2' => $link,
			'Timeout'  => $timeout
		);

		unless ( defined($sent) ) {
			return undef;
		}

		my $reply = $this->receiveanswer();

		unless ( defined($reply) ) {
			return undef;
		}

		if ($debug) {
			$logger->log( 'info', sprintf( '%s', Dumper($reply) ) );
		}

		$status = $reply->{'Response'};

		unless ( defined($status) ) {
			$this->seterror('No response');
			return undef;
		}

		if ( $status ne 'Success' ) {
			$this->seterror('Status: Response not success');
			return undef;
		}

		return 1;

	} ## end while ( $i <= $#liststatus)
	$this->seterror("Can't find channel: $channel");
	return undef;

} ## end sub park

=item B<get_parked_calls> 

Get the array of parked calls.  

=cut 

sub get_parked_calls {
	my $this = shift;

	my $sent = $this->sendcommand( 'Action' => 'ParkedCalls' );

	unless ( defined($sent) ) {
		$this->seterror("Can't send command ParkedCalls");
		return undef;
	}

	my $reply = $this->receiveanswer();

	unless ( defined($reply) ) {
		$this->seterror("Can't receive answer");
		return undef;
	}

	my $status = $reply->{'Response'};

	unless ( defined($status) ) {
		$this->seterror("Can't get status");
		return undef;
	}

	if ( $status ne "Success" ) {
		$this->seterror("Status not success");
		return undef;
	}

	my @replies;
	while (1) {
		$reply  = $this->receiveanswer();
		$status = $reply->{'Event'};
		if ( $status eq 'ParkedCallsComplete' ) {
			last;
		}
		push @replies, $reply;
	}
	return @replies;
} ## end sub get_parked_calls

=item B<find_parked_call(channel)>

 Find the parked call by channel name 

=cut 

sub find_parked_call {
	my $this    = shift;
	my $channel = shift;

	my @parkedcalls = $this->get_parked_calls();

	unless (@parkedcalls) {
		return undef;
	}

	my $i = 0;

	while ( $i <= $#parkedcalls ) {
		my $parkedcall = $parkedcalls[ $i++ ];

		if ( $parkedcall->{'Channel'} eq $channel ) {
			return $parkedcall;
		}
	}
	return undef;
} ## end sub find_parked_call

1;
