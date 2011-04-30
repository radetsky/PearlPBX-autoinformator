#===============================================================================
#
#         FILE:  AutoInformator.pm
#
#  DESCRIPTION:  Core class for NetSDS-VoiceInformer. 
# 							 
#
#        NOTES:  ---
#       AUTHOR:  Alex Radetsky (Rad), <rad@rad.kiev.ua>
#      COMPANY:  Net.Style
#      VERSION:  1.0
#      CREATED:  04/25/11 15:09:44 EEST
#===============================================================================
=head1 NAME

NetSDS::

=head1 SYNOPSIS

	use NetSDS::;

=head1 DESCRIPTION

C<NetSDS> module contains superclass all other classes should be inherited from.

=cut

package NetSDS::AutoInformator;

use 5.8.0;
use strict;
use warnings;

use Data::Dumper; 
use NetSDS::Asterisk::Originator;
use NetSDS::Asterisk::EventListener; 
use NetSDS::DBI; 
use NetSDS::Logger; 
use Date::Manip; 
use Carp; 
use base qw(NetSDS::Class::Abstract);

use version; our $VERSION = "0.01";
our @EXPORT_OK = qw();

__PACKAGE__->mk_accessors('logger');

#===============================================================================
#
=head1 CLASS METHODS

=over

=item B<new([...])> - class constructor

    my $object = NetSDS::SomeClass->new(%options);

=cut

#-----------------------------------------------------------------------
sub new {

	my ( $class, %params ) = @_;
	
  my $this = $class->SUPER::new(%params);

	return $this;

};

#***********************************************************************
=head1 OBJECT METHODS

=over

=item B<user(...)> - object method

=cut

#-----------------------------------------------------------------------
__PACKAGE__->mk_accessors('dbh');

=item B<start> 

Connects to the syslog, asterisk and database. 
returns undef if some operation failed. 

=cut 

sub start {

	my ( $this, %attrs ) = @_;

  # Create syslog handler
  if ( !$this->logger ) {
    $this->logger( NetSDS::Logger->new ( name =>'NetSDS-AutoInformator#'. $this->{target_name} ) );
    $this->log( "info", "Logger started" );
  }

  # Try to connect to the DSN: 
  my $dsn    = $this->{target}->{'dsn'}; 
  my $login  = $this->{target}->{'login'}; 
  my $passwd = $this->{target}->{'passwd'}; 
  
  $this->dbh ( NetSDS::DBI->new ( 
		dsn    => $dsn, 
    login  => $login, 
    passwd => $passwd,
  ) ); 

  unless ( defined ( $this->dbh->{dbh} ) ) { 
	  $this->log("error",$this->dbh->{_errstr}); 
		die; 
  }

  # Checks for table exists
  my $table = $this->{target}->{'table'}; 
  my $sth = $this->dbh->call("select count(*) from ".$table);
  my $row = $sth->fetchrow_hashref();
  unless ( defined ($row ) ) { 
		# table does not exist; 
	  $this->log("error", "Table $table does not exist.");
	  die;  
  }
 
  # Asterisk connect   
  # Set Asterisk Parameters
  my $astManagerHost   = $this->{conf}->{'asterisk'}->{'astManagerHost'};
  my $astManagerPort   = $this->{conf}->{'asterisk'}->{'astManagerPort'};
  my $astManagerUser   = $this->{conf}->{'asterisk'}->{'astManagerUser'};
  my $astManagerSecret = $this->{conf}->{'asterisk'}->{'astManagerSecret'};  

  # Set Event Listener
  my $event_listener = NetSDS::Asterisk::EventListener->new(
        host     => $astManagerHost,
        port     => $astManagerPort,
        username => $astManagerUser,
        secret   => $astManagerSecret
  );

  my $el_connected = $event_listener->_connect(); 
  unless ( defined ( $el_connected ) ) { 
		$this->log("error","Can't connect to asterisk via $astManagerHost:$astManagerPort"); 
	  die; 
  }

	return 1; 

};

=item B<run> 

  Reading the database, run async many calls.  

=cut 

sub run { 
  my $this = shift; 
  while (1) {
    my $is_allowed_time = $this->_is_allowed_time();  
	  unless ( defined ( $is_allowed_time) ) { 
			sleep(5); 
		}
    # Now it's allowed. Let's find parameters of target and get next N records; 
    my $next_records_count = $this->_get_next_records_count(); 


  }
	return 1; 
} 

=item B<_get_next_records_count> 

 Analyze the target parameters and find the correspondent count for next records

=cut 

sub _gext_next_records_count { 
	my $this = shift; 
  unless ( defined ( $this->{target}->{'maxcalls'} ) ) { 
		$this->log ("warning","maxcalls undefined. Epic Fail."); 
		return undef; 
	} 
	if ($this->{target}->{'maxcalls'} =~ /auto/i ) { 
		if ( defined ( $this->{target}->{'queue'} ) ) { 
			my $maxcalls = $this->_get_queue_free_operators ($this->{target}->{'queue'});
		  unless ( defined ($maxcalls) ) {
				$this->log("warning","Can't get free operators. Epic Fail."); 
				return undef; 
			} 
			if ( defined ( $this->{target}->{'predictive_calls'} ) ) { 
				$maxcalls += $this->{target}->{'predictive_calls'}; 
			}
			return $maxcalls; 
		}
		$this->log("warning","Maxcalls=auto but queue undefined."); 
		return undef; 
	}
  my $maxcalls = $this->{target}->{'maxcalls'}; 
	unless ( $maxcalls ) { 
		$this->log ("warning", "maxcalls must be > 0"); 
		return undef; 
	} 
  return $maxcalls; 

}
=item B<_is_allowed_time>

  Check for allowed_time. When allowed time undefined allow to call any time. 

=cut 

sub _is_allowed_time { 
  my $this = shift;

	unless ( defined (  $this->{conf}->{allowed_time} ) ) {
	  $this->log ("info", "Config does not contain allowed_time. Allow it 24h. "); 
		return 1; 
  }

  my ($begin,$end) = split('-',$this->{conf}->{allowed_time}); 
  my $now    = ParseDate('now'); 
  my $today  = ParseDate('today'); 
  my $tbegin = ParseDate( $begin  ); 
  my $tend   = ParseDate ( $end  ); 

  my $flag1 = Date_Cmp($now,$tbegin); 
	my $flag2 = Date_Cmp($now,$tend);
  
	if ($flag1 > 0 and $flag2 < 0 ) {
	  $this->log("info","Allowed time between ".Dumper ($tbegin) . " and " . Dumper ($tend) ); 
		return 1; 
	}
	$this->log("info"," Not Allow to call !"); 
	return undef; 

}
=item B<stop>

  Stops connections to database, asterisk, syslog. 

=cut 
sub stop { 

	my $this = shift; 

  return 1; 

} 

sub log {

  my ( $this, $level, $message ) = @_;
  # Try to use syslog handler
  if ( $this->logger() ) {
    $this->logger->log( $level, $message );
  } else {
    carp "[$level] $message";
  }
  return undef;
}    ## sub log


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


