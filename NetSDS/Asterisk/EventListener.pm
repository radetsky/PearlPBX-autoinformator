package NetSDS::Asterisk::EventListener;

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

use NetSDS::Asterisk::Manager;
use Data::Dumper;

our $VERSION = '0.01';

=pod

=head2 new

  my $object = Module::Name->new(
      host => 'bar',
	  port => '5038',
	  username => 'user',
	  secret => 'secpas'
  );

The C<new> constructor lets you create a new B<Module::Name> object.

So no big surprises there...

Returns a new B<Module::Name> or dies on error.

=cut

sub new {
    my ( $class, %params ) = @_;

    my $self = $class->SUPER::new(
        name        => undef,    # application name
        pid         => $$,       # proccess PID
        debug       => undef,    # debug mode flag
        daemon      => undef,    # daemonize if 1
        verbose     => undef,    # be more verbose if 1
        use_pidfile => undef,    # check PID file if 1
        pid_dir     =>
          '/var/run/NetSDS',    # PID files catalog (default is /var/run/NetSDS)
        conf_file     => undef, # configuration file name
        conf          => undef, # configuration data
        logger        => undef, # logger object
        has_conf      => 1,     # is configuration file necessary
        auto_features => 0,     # are automatic features allowed or not
        infinite      => 1,     # is infinite loop
        edr_file      => undef, # path to EDR file
        %params,
    );
    return $self;
}

=pod

=head2 dummy

This method does something... apparently.

=cut

__PACKAGE__->mk_accessors('manager');
__PACKAGE__->mk_accessors('connected');

sub _connect {
    my ( $this, $host, $port, $user, $secret ) = @_;

    my $manager = NetSDS::Asterisk::Manager->new ( 
		host => $this->{'host'},
		port => $this->{'port'},
		username => $this->{'username'},
		secret => $this->{'secret'},
		events => 'On'
	); 
    unless ( defined ($manager) ) { 
	return undef; 
    }

    $this->manager( $manager );
    my $res = $this->manager->connect();
    unless ( defined ( $res ) ) {
			$this->{'error'} = $this->manager->geterror(); 
		return undef; 
    }
    $this->connected(1);

    return 1;
}

sub _getEvent {
    my $this = shift;

    unless ( defined ( $this->connected ) )  {
        $this->connected( $this->_connect() );
    }

    my $event = $this->manager->receive_answer();
    unless ( defined($event) ) {
        return undef;
    }
    return $event;
}

1;

=pod

=head1 SUPPORT

No support is available

=head1 AUTHOR

Copyright 2009-2010 Alex Radetsky <rad@rad.kiev.ua> 

=cut

