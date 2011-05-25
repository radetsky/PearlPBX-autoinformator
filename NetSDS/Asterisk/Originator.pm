package NetSDS::Asterisk::Originator;

=pod

=head1 NAME

Module::Name - My author was too lazy to write an abstract

=head1 SYNOPSIS

  my $object = Module::Name->new(
      foo  => 'bar',
      flag => 1,
  );
  
  $object->dummy;

=head1 DESCRIPTION

The author was too lazy to write a description.

=head1 METHODS

=cut

use 5.8.0;
use strict;
use warnings;

use base 'NetSDS::Class::Abstract';

use NetSDS::AMI; 
use Data::Dumper; 


our $VERSION = '0.01';

=pod

=head2 new

  my $object = Module::Name->new(
      foo => 'bar',
  );

The C<new> constructor lets you create a new B<Module::Name> object.

So no big surprises there...

Returns a new B<Module::Name> or dies on error.

=cut

sub new {
	my ( $class, %params ) = @_;

	my $self = $class->SUPER::new(
		name          => undef,                # application name
		pid           => $$,                   # proccess PID
		debug         => undef,                # debug mode flag
		daemon        => undef,                # daemonize if 1
		verbose       => undef,                # be more verbose if 1
		use_pidfile   => undef,                # check PID file if 1
		pid_dir       => '/var/run/NetSDS',    # PID files catalog (default is /var/run/NetSDS)
		conf_file     => undef,                # configuration file name
		conf          => undef,                # configuration data
		logger        => undef,                # logger object
		has_conf      => 1,                    # is configuration file necessary
		auto_features => 0,                    # are automatic features allowed or not
		infinite      => 1,                    # is infinite loop
		edr_file      => undef,                # path to EDR file
		%params,
	);
	return $self;
}

=pod

=head2 dummy

This method does something... apparently.

=cut

__PACKAGE__->mk_accessors('AMI');
__PACKAGE__->mk_accessors('connected');

sub _connect {
	my ( $this, $host, $port, $user, $secret ) = @_;

	$this->AMI(NetSDS::AMI->new());

	$this->connected (  $this->AMI->connect( $host, $port, $user, $secret, 'Off' ) );
	
	unless ( defined( $this->connected ) ) {
		return undef;
	}
	return 1;
}

sub originate {
	my ( $this, $host, $port, $user, $secret ) = @_;

	unless ( defined ( $this->{'destination'} ) ) { 
		return undef; 
	}

	unless ( $this->connected ) {
		 
		$this->connected ( $this->_connect( $host, $port, $user, $secret, 'Off' ) );
	}
	

	my $destination    = $this->{'destination'}; 
	my $callerid       = $this->{'callerid'}; 
	my $return_context = $this->{'return_context'};
        my $variables       = $this->{'variables'}; 
	my $channel        = $this->{'channel'};
        my $sent; 
        if ( defined ($this->{'actionid'} ) ) {
		 $sent =  $this->AMI->sendcommand (
	              Action  => 'Originate',
	              Async   => 'On',
       	              Channel => $channel,
                      Exten   => $destination,
		      Timeout => 30000,
                      Context => $return_context,
                      CallerID => $callerid,
                      Variable => $variables,
		      ActionID => $this->{'actionid'}
        	);
        } else { 
 		 $sent = $this->AMI->sendcommand ( 
        		Action  => 'Originate',
        		Async   => 'On',
       		 	Channel => $channel,
       		 	Exten   => $destination, 
       	 		Context => $return_context,
			Timeout => 30000, 
        		CallerID => $callerid,
        		Variable => $variables, 
        	); 
	}
        unless ( defined ($sent) ) { 
        	return undef; 
        } 
        
        my $reply = $this->AMI->receiveanswer(); 
        if ($reply->{'Response'} =~ /Success/i ) { 
        	return 1; 
        } 
	return undef;
}

1;

=pod

=head1 SUPPORT

No support is available

=head1 AUTHOR

Copyright 2009 Anonymous.

=cut
