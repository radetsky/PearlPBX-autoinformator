#===============================================================================
#
#         FILE:  Manager.pm
#
#  DESCRIPTION:  Non-blocking IO module talking with Asterisk Manager Interface
#
#        NOTES:  ---
#       AUTHOR:  Alex Radetsky (Rad), <rad@rad.kiev.ua>
#      COMPANY:  Net.Style
#      VERSION:  1.0
#      CREATED:  29.10.2010 19:56:12 EEST
#===============================================================================

=head1 NAME

NetSDS::

=head1 SYNOPSIS

	use NetSDS::Asterisk::Manager; 

=head1 DESCRIPTION

C<NetSDS> module contains superclass all other classes should be inherited from.

=cut

package NetSDS::Asterisk::Manager;

use 5.8.0;
use strict;
use warnings;

use base qw(NetSDS::Class::Abstract);

use IO::Socket;
use IO::Select;
use POSIX;
use bytes;
use Data::Dumper;
use NetSDS::Logger;

use version; our $VERSION = "0.01";
our @EXPORT_OK = qw();

my @replies;

#===============================================================================
#

=head1 CLASS METHODS

=over

=item B<new([...])> - class constructor

    my $object = NetSDS::Asterisk::Manager->new(
		host => $host,
		port => $port, 
		username => $username,
		secret => $secret,
		events => $events
	);



=cut

#-----------------------------------------------------------------------
sub new {

    my ( $class, %params ) = @_;

    my $this = $class->SUPER::new(%params);

    return $this;

}

#***********************************************************************

=head1 OBJECT METHODS

=over

=item B<user(...)> - object method

=cut

#-----------------------------------------------------------------------
__PACKAGE__->mk_accessors('user');
__PACKAGE__->mk_accessors('logger');
__PACKAGE__->mk_accessors('strerror');
__PACKAGE__->mk_accessors('socket');
__PACKAGE__->mk_accessors('select');

=cut 

=item B<geterror> 

 Method geterror returns last error state in human readable form AKA string

=cut 

sub geterror {
    my $this = shift;
    return $this->strerror;
}

=item B<seterror> 

 Method setserror set error state from first parameter. Do not use it. It's internal/private method of the class. 
 
=cut 

sub seterror {
    my $this = shift;
    my $str  = shift;

    $this->strerror($str);

    #$this->log("warning",$str);
}

=item B<connect (host, port, username, secret, events); >

 Connect tries to connect to the Asterisk manager with defined parameters.

=cut 

sub connect {
    my $this = shift;

    unless ( defined( $this->{'host'} ) ) {
        $this->seterror( sprintf("Missing host address.\n") );
        return undef;
    }
    unless ( defined( $this->{'port'} ) ) {
        $this->seterror( sprintf("Missing port. \n") );
        return undef;
    }
    unless ( defined( $this->{'username'} ) ) {
        $this->seterror( sprintf("Missing username.\n") );
        return undef;
    }
    unless ( defined( $this->{'secret'} ) ) {
        $this->seterror( sprintf("Missing secret.\n") );
        return undef;
    }

    unless ( defined( $this->{'events'} ) ) {
        $this->{'events'} = 'On';
    }

    my $socket = IO::Socket::INET->new(
        PeerAddr  => $this->{'host'},
        PeerPort  => $this->{'port'},
        Proto     => "tcp",
        Timeout   => 30,
        Type      => SOCK_STREAM(),
        ReuseAddr => 1,
    );

    unless ( $socket and $socket->connected ) {
        $this->seterror( sprintf( "Can't connect: %s\n", $! ) );
        return undef;
    }
    $socket->autoflush(1);

    $this->socket($socket);

    my $select = IO::Select->new();
    unless ( defined($select) ) {
        $this->seterror("Can't create select object.");
        return undef;
    }
    $this->select($select);
    $this->select->add($socket);

    my $reply = $this->read_raw(1);
    unless ( defined($reply) ) {
        return undef;
    }

 # Нет ответа? Значит не туда присоединились.
    if ( $reply =~ m/^(Asterisk Call Manager)\/(\d+\.\d+\w*)/is ) {
        my $manager = $1;
        my $version = $2;
    }
    else {
        $reply =~ s/[\r\n]+$//;
        $this->seterror( sprintf( "Unknown Protocol. %s\n", $reply ) );
        return undef;
    }

    my $login =
      $this->login( $this->{'username'}, $this->{'secret'}, $this->{'events'} );

    unless ( defined($login) ) {
        return undef;
    }
    return 1;

} ## end sub connect

sub reconnect {
    my $this = shift;

    unless ( $this->socket and $this->socket->connected ) {
        my $tries = 0;
        while ( $tries <= 5 ) {
            my $result = $this->connect();
            if ($result) {
                return 1;
            }
            $tries++;
            sleep(1);
        }
    }
    return undef;
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
    my $sent = $this->write_raw($text);
    unless ( defined($sent) ) {
        $this->reconnect();
        $sent = $this->write_raw($text);
        unless ( defined($sent) ) {
            return undef;
        }
    }
    return $sent;
} ## end sub sendcommand

=item B<receiveanswer> 

 Example: 

 my $reply = $ami->receiveanswer ( ) ;
 print $reply->{'Response'}; 

 Use receiveanswer to receive any answer from Asterisk manager. 

=cut 

sub receive_answer {
    my $this = shift;

# Если в буфере что-то еще есть, отдаем оттуда.

    my $reply = shift @replies;
    if ( defined($reply) ) {
        return $reply;
    }

    my $result = $this->read_raw();
    unless ( defined($result) ) {
        unless ( ( $this->socket ) and ( $this->socket->connected ) ) {
            $result = $this->reconnect();
            unless ( defined($result) ) {
                $this->seterror("Socket disconnected.");
                return undef;
            }
        }
        return undef;
    }

    unless ($result) {
        return 0;
    }

    @replies = $this->reply_to_hash($result);

    unless (@replies) {
        $this->seterror("Reply to hash: error.");
        return undef;
    }

    return shift @replies;

} ## end sub receiveanswer

=item B<read_raw> 

 Method read_raw reads bytes from socket and returns it as result. If any error occured then method returns undef. 

=cut 

sub read_raw {
    my $this = shift;
    my $one  = @_;
    if ($one) {
        return $this->socket->getline;
    }

    unless ( $this->socket ) {
        $this->seterror("Read from closed socket.");
        return undef;
    }
    unless ( $this->socket->connected ) {
        $this->seterror("Read from disconnected socket.");
        return undef;
    }

    my $data = '';
    my $force = 0.2; 

    while (1) {
        unless ( $this->select->can_read($force) ) {
            if ( $data eq '' )
            { # Еще ничего не прочитано, то возвращаем ошибку.
                return 0;
            }
            else {
                return $data;
            }
        }

        my $buf = '';
        my $res = sysread( $this->socket, $buf, 1024 );
        unless ( defined($res) ) {
            $this->select->remove( $this->socket );
            $this->seterror(
                sprintf( "Error while reading socket: %s\n", $! ) );
            return undef;
        }
        if ( $res > 0 ) {
            $data .= $buf;
        }
        if ( $res < 1024 ) {    # Вычитали все, что было.
					if ($buf =~ /\r\n\r\n$/) { 
            last;
					} else { 
						# Форсированное чтение пока не получим \r\n в конце 
						$force = 10; 
						next;
					}
        }
        if ( $res >= 1024 ) {
            next;
        }
    }    #### end while (1);
    return $data;
} ## end sub read_raw

=item B<login ( username, secret, events );> 

 Private method. Please use connect(); 

=cut 

sub login {
    my $this = shift;

    my ( $manager_username, $manager_secret, $manager_events ) = @_;

    my $sent = $this->sendcommand(
        Action   => 'Login',
        Username => $manager_username,
        Secret   => $manager_secret,
        Events   => $manager_events,
    );

    unless ( defined($sent) ) {
        return undef;
    }

    my $tries = 0;
    my $reply;
    while ( $tries < 5 ) {
        $reply = $this->receive_answer();
        unless ( defined($reply) ) {
            return undef;
        }
        if ( $reply == 0 ) {
            $tries = $tries + 1;
            next;
        }
        last;
    }

    if ( $reply == 0 ) {
        $this->seterror("No answer from asterisk.");
        return undef;
    }

    my $status = $reply->{'Response'};
    unless ( defined($status) ) {
        $this->seterror( sprintf("Undefined Response: ".Dumper($reply)."\n") );
        return undef;
    }

    if ( $status eq 'Success' ) {
        return 1;
    }
    elsif ( $status eq 'Error' ) {
        $this->seterror(
            sprintf( "Error while logging in. Reply messages was: %s\n",
                $reply->{'Message'} )
        );
        return undef;
    }
    else {
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
    my @arrEvents;

    my (@rows) = split( /\r\n/, $reply );

    foreach my $row (@rows) {
        if ( $row eq '' ) {
            push @arrEvents, $answer;
            $answer = undef;
        }

        if ($row) {
            if ( $row =~ m/\n/ ) {
                my @arr = split( m/\n/, $row );

                $arr[$#arr] =~ s/--END COMMAND--$//;

                $answer->{'raw'} = @arr;
            }
            else {
                ( $key, $val ) = $row =~ m/^(\w+):\s*(.*)\s*$/;
                unless ($key) {
                    next;
                }
                $answer->{$key} = $val;
            }
        }
    }
    push @arrEvents, $answer;
    return @arrEvents;
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
                $answer->{'raw'} = @arr;
            }
            else {
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
        }
        else {
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

    unless ( $this->socket ) {
        $this->seterror("Can't write to closed socket.");
        return undef;
    }

    unless ( $this->socket->connected ) {
        $this->seterror("Can't write to disconnected socket.\n");
        return undef;
    }

    my $size = bytes::length($data);

    if ( $this->socket->print($data) ) {
        unless ( $this->socket->flush ) {
            $this->seterror("Error while flushing socket");
            return undef;
        }
    }
    else {
        $this->seterror( sprintf( "Error while writing to socket: %s\n", $! ) );
        return undef;
    }
    return $size;
} ## end sub write_raw

1;

__END__

=back

=head1 EXAMPLES


=head1 BUGS

Unknown yet

=head1 SEE ALSO

None

=head1 TODO

None

=head1 AUTHOR

Alex Radetsky <rad@rad.kiev.ua>

=cut


