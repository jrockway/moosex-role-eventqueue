use strict;
use warnings;
use Test::More;
use Test::Exception;

{
    package Class;
    use Moose;
    use namespace::autoclean;

    with 'MooseX::Role::EventQueue' => {
        name          => 'read',
        error_handler => sub { die "XXX: $_[1]" },
    };

    Class->meta->make_immutable;
}

my @default;

my $foo = Class->new( on_read => sub { shift; push @default, @_ } );

can_ok $foo, '_handle_read';

$foo->_handle_read('this is some data', 'and some more');

is_deeply \@default, ['this is some data', 'and some more'],
    'read was handled by the on_read handler';

@default = ();

{
    my $pushed;

    can_ok $foo, 'has_pending_read_handler', 'push_read';

    ok !$foo->has_pending_read_handler, 'no pending read handler';

    $foo->push_read( sub { $pushed = $_[1] } );
    ok $foo->has_pending_read_handler, 'has pending read handler now';

    $foo->_handle_read( 'data yay' );
    is $pushed, 'data yay', 'push_read handler handled the read';
    is_deeply [@default], [], 'nothing was written to @default, either';

    ok !$foo->has_pending_read_handler, 'no pending read handler, it was used';
}

{
    can_ok $foo, 'clear_on_read', 'has_queued_read_data';
    $foo->clear_on_read;

    ok !$foo->has_queued_read_data, 'no queued read data yet';
    $foo->_handle_read('foo', 'bar');
    $foo->_handle_read('OH HAI');
    $foo->_handle_read({ refs => 'are also ok'});
    is $foo->has_queued_read_data, 3, 'has some queued read data';

    my $pushed;
    $foo->push_read( sub { $pushed = [$_[1], $_[2]] } );
    is_deeply $pushed, ['foo', 'bar'], 'got data';
    is $foo->has_queued_read_data, 2, 'still has some queued read data';

    @default = ();
    $foo->on_read( sub { shift; push @default, @_ } );
    is_deeply [@default], [ 'OH HAI', { refs => 'are also ok' } ],
        'got the rest of the data';

    ok !$foo->has_queued_read_data, 'now there is no queued read data';

    @default = ();
    $foo->_handle_read('read');
    is_deeply [@default], ['read'], 'handler "back to normal"';
    ok !$foo->has_queued_read_data, 'no queued read data';
}

{
    $foo->clear_on_read;

    lives_ok {
        $foo->push_read(sub { die 'EXCEPTIONALLY BAD SITUATION' });
    } 'exception is deferred';

    throws_ok {
        $foo->_handle_read('OH NOES');
    } qr/XXX: EXCEPTIONALLY BAD SITUATION/, 'our error handler fires';

    lives_ok {
        $foo->_handle_read('to queue');
        $foo->_handle_read('and another');
    } 'queuing data is fine';

    is $foo->has_queued_read_data, 2, '2 things in Q';

    throws_ok {
        $foo->push_read(sub { die '<whistling noise>' });
    } qr/XXX: <whistling noise>/, 'handler fires';

    is $foo->has_queued_read_data, 1, '1 thing in Q';

    throws_ok {
        $foo->on_read(sub { die 'this code is faulty' });
    } qr/XXX: this code is faulty/, 'handler fires';

    ok !$foo->has_queued_read_data, 'everything is gone from the Q';
}

done_testing;
