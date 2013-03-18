use strict;
use warnings;
package Mojolicious::Plugin::LeakTracker;
# ABSTRACT: Helps you track down memory leaks in your code
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::Base 'Class::Data::Inheritable';

use Devel::Events::Filter::Stamp;
use Devel::Events::Filter::RemoveFields;
use Devel::Events::Filter::Stringify;
use Devel::Events::Handler::Log::Memory;
use Devel::Events::Handler::Multiplex;
use Devel::Events::Generator::Objects;
use Devel::Events::Handler::ObjectTracker;

my $request_id = 1;

__PACKAGE__->mk_classdata($_) for(qw/
    object_trackers
    object_tracker_hash
    devel_events_log
    devel_events_filters
    devel_events_multiplexer
    devel_events_generator
    /);

sub register {
    my $self = shift;
    my $args = { no_routes => 1, @_ };

    $self->object_trackers([]);
    $self->object_tracker_hash({});

    my $log          = $self->create_devel_events_log;
    my $filtered_log = $self->create_devel_events_log_filter($log);
    my $multiplexer  = $self->create_devel_events_multiplexer;
    my $filters      = $self->create_devel_events_filter_chain($multiplexer);
    my $generator    = $self->create_devel_events_objects_event_generator($filters);

    $self->devel_events_log($log);
    $self->devel_events_multiplexer($multiplexer);
    $self->devel_events_filters($filters);
    $self->devel_events_generator($generator);

    for(qw/around_dispatch/) {
        my $s = 'hook_' . $_;
        $self->hook($_ => $self->can($s));
    }

    return 1 if(defined($args{'no_routes'}) && $args{'no_routes'} == 1);

    # set up some specific routes for dumping info, they'll be attached 
    # under '_leak'

    my $r = $self->routes;
}

sub send_devel_event {
    my $self = shift;
    my @event = (@_);

    $self->devel_events_filters->new_event(@event);
}

sub create_devel_events_log {
    return Devel::Events::Handler::Log::Memory->new();
}

sub create_devel_events_log_filter {
    my $self = shift;
    my $log  = shift;

    return Devel::Events::Filter::Stringify->new(handler => $log);
}

sub create_devel_events_multiplexer {
    return Devel::Events::Handler::Multiplex->new();
}

sub create_devel_events_object_tracker {
    return Devel::Events::Handler::ObjectTracker->new();
}

sub create_devel_events_object_event_generator {
    my $self = shift;
    my $filters = shift;

    return Devel::Events::Generator::Objects->new(handler => $filters);
}

sub create_devel_events_filter_chain {
    my $self = shift;
    my $multiplexer = shift;

    return Devel::Events::Filter::Stamp->new(
        handler => Devel::Events::Filter::RemoveFields->new(
            fields => [qw/generator/],
            handler => $multiplexer,
        )
    );
}

sub get_all_request_ids {
    my $self = shift;
    return map { my ( $type, %req ) = @$_; $req{request_id} } $self->get_all_request_begin_events;
}

sub get_all_request_begin_events {
    my $self = shift;
    return $self->devel_events_log->grep("request_begin");
}

sub get_request_events {
    my $self = shift;
    my $request_id = shift;
    return $self->devel_events_log->limit( from => { request_id => $request_id }, to => "request_end" );
}

sub get_event_by_id {
    my $self = shift;
    my $event_id = shift;

    if (my $event = ( $self->devel_events_log->grep({ id => $event_id }) )[0] ) {
        return @$event;
    } else {
        return undef;
    }
}

sub generate_stack_for_event {
    my ( $c, $request_id, $event_id ) = @_;

    my @events = $c->devel_events_log->limit( from => { request_id => $request_id }, to => { id => $event_id } );

    my @stack;
    foreach my $event ( @events ) {
        my ( $type, %data ) = @$event;

        if ( $type eq 'enter_action' ) {
            push @stack, \%data;
        } elsif ( $type eq 'leave_action' ) {
            pop @stack;
        }
    }

    return @stack;
}

sub get_object_tracker_by_id {
    my $self = shift;
    my $request_id = shift;$

    return $self->object_tracker_hash->{$request_id};
}

sub get_object_entry_by_id {
    my $self = shift;
    my $request_id = shift;
    my $id = shift;

    if ( my $tracker = $self->get_object_tracker_by_id($request_id) ) {
        my $live_objects = $tracker->live_objects;

        foreach my $obj ( values %$live_objects ) {
            return $obj if $obj->{id} == $id;
        }
    }
    return undef;
}

sub get_object_by_event_id {
    my $self = shift;
    my $request_id = shift;
    my $id = shift;

    if ( my $entry = $self->get_object_entry_by_id( $request_id, $id ) ) {
        return $entry->{object};
    } else {
        return;
    }
}

###
##  Hooks below
#

sub hook_around_dispatch {
    my $next = shift;
    my $c    = shift;

    ++$request_id;
    $c->app->send_devel_event(request_begin => (app => $c->app, request_id => $request_id));

    my $tracker = $c->app->create_devel_events_object_tracker;

    push(@{$c->app->object_trackers}, $tracker);
    $c->app->object_tracker_hash->{$request_id} = $tracker;

    my $multiplexer = $c->app->devel_events_multiplexer;
    $multiplexer->add_handler($tracker);

    my $generator = $c->app->devel_events_generator;
    $generator->enable;

    $next->(); # 

    $generator->disable;
    $multiplexer->remove_handler($tracker);

    $c->app->send_devel_event(request_end => (app => $c->app, status => $c->res->status, request_id => $request_id));
}

1;
=pod
=head1 BUGS/CONTRIBUTING

Please report any bugs or feature requests through the web interface at L<https://github.com/benvanstaveren/Mojolicious-Plugin-LeakTracker/issues>. 
You can fork my Git repository at L<https://github.com/benvanstaveren/Mojolicious-Plugin-LeakTracker/> if you want to make changes or supply me with patches.

=cut
