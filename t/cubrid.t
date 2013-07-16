#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More 0.94;
use Test::MockModule;
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);
use Capture::Tiny 0.12 qw(:all);
use Try::Tiny;
use App::Sqitch;
use App::Sqitch::Plan;
use lib 't/lib';
use DBIEngineTest;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::cubrid';
    require_ok $CLASS or die;
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.conf';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.conf';
}

is_deeply [$CLASS->config_vars], [
    client    => 'any',
    user      => 'any',
    password  => 'any',
    db_name   => 'any',
    host      => 'any',
    port      => 'int',
    sqitch_db => 'any',
], 'config_vars should return 7 vars';

my $sqitch = App::Sqitch->new;
isa_ok my $cub = $CLASS->new(sqitch => $sqitch), $CLASS;

my $client = 'csql' . ($^O eq 'MSWin32' ? '.exe' : '');
is $cub->client, $client, 'client should default to csql';
is $cub->sqitch_db, 'sqitch', 'sqitch_db default should be "sqitch"';
for my $attr (qw(user password db_name host port destination)) {
    is $cub->$attr, undef, "$attr default should be undef";
}

is $cub->meta_destination, $cub->sqitch_db,
    'Meta destination should be same as sqitch_db';

my @std_opts = (
    '--CS-mode',
    '--single-line',
    '--no-pager',
);
is_deeply [$cub->csql], [$client, @std_opts],
    'csql command should be std opts-only';

isa_ok $cub = $CLASS->new(sqitch => $sqitch, db_name => 'foo'), $CLASS;
ok $cub->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$cub->csql], [
    $client,
    # '--foo' => 'baz',
    # '--whu' => 'hi there',
    # '--yo'  => 'stellar',
    @std_opts,
    'foo',
], 'Variables should not be passed to csql';

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.cubrid.client'    => '/path/to/csql',
    'core.cubrid.user'      => 'freddy',
    'core.cubrid.password'  => 's3cr3t',
    'core.cubrid.db_name'   => 'widgets',
    'core.cubrid.host'      => 'db.example.com',
    'core.cubrid.port'      => 1234,
    'core.cubrid.sqitch_db' => 'meta',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $cub = $CLASS->new(sqitch => $sqitch), 'Create another cub';

is $cub->client, '/path/to/csql', 'client should be as configured';
is $cub->user, 'freddy', 'username should be as configured';
is $cub->password, 's3cr3t', 'password should be as configured';
is $cub->db_name, 'widgets', 'db_name should be as configured';
is $cub->destination, 'widgets', 'destination should default to db_name';
is $cub->meta_destination, 'meta', 'meta_destination should default to sqitch_db';
is $cub->host, 'db.example.com', 'host should be as configured';
is $cub->port, 1234, 'port should be as configured';
is $cub->sqitch_db, 'meta', 'sqitch_db should still be as configured';
is_deeply [$cub->csql], [qw(
    /path/to/csql
    --user freddy
    --password s3cr3t
    --CS-mode
    --single-line
    --no-pager
    widgets@db.example.com
)], 'csql command should be configured';

# ##############################################################################
# # Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    db_client   => '/some/other/csql',
    db_username => 'anna',
    db_name     => 'widgets_dev',
    db_host     => 'foo.com',
    db_port     => 98760,
);

ok $cub = $CLASS->new(sqitch => $sqitch),
    'Create a cubrid with sqitch with options';

is $cub->client, '/some/other/csql', 'client should be as optioned';
is $cub->user, 'anna', 'username should be as optioned';
is $cub->password, 's3cr3t', 'password should still be as configured';
is $cub->db_name, 'widgets_dev', 'db_name should be as optioned';
is $cub->destination, 'widgets_dev', 'destination should still default to db_name';
is $cub->meta_destination, 'meta', 'meta_destination should still default to sqitch_db';
is $cub->host, 'foo.com', 'host should be as optioned';
is $cub->port, 98760, 'port should be as optioned';
is $cub->sqitch_db, 'meta', 'sqitch_db should still be as configured';
is_deeply [$cub->csql], [qw(
    /some/other/csql
    --user     anna
    --password s3cr3t
    --CS-mode
    --single-line
    --no-pager
    widgets_dev@foo.com
)], 'csql command should be as optioned';

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $cub, qw(_run _capture _spool);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my ( @run, $exp_pass );
$mock_sqitch->mock( run => sub { shift; @run = @_; });

my @capture;
$mock_sqitch->mock(capture => sub { shift; @capture = @_; });

my @spool;
$mock_sqitch->mock(spool => sub { shift; @spool = @_; });

$exp_pass = 's3cr3t';
ok $cub->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$cub->csql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $cub->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $cub->csql],
    'Command should be passed to spool()';

ok $cub->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$cub->csql, qw(foo bar baz)],
    'Command should be passed to capture()';

# ##############################################################################
# Test file and handle running.
ok $cub->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$cub->csql, '--input-file', 'foo/bar.sql'],
    'File should be passed to run()';

ok $cub->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $cub->csql],
    'Handle should be passed to spool()';

# Verify should go to capture unless verosity is > 1.
ok $cub->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, [$cub->csql, '--input-file', 'foo/bar.sql'],
    'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $cub->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, [$cub->csql, '--input-file', 'foo/bar.sql'],
    'Verifile file should be passed to run() for high verbosity';

$mock_sqitch->unmock_all;
$mock_config->unmock_all;

# ##############################################################################
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char'), "$CLASS->can('_ts2char')";
is $ts2char->('foo'),
    q{to_char(foo AT TIME ZONE 'UTC', 'YYYY:MM:DD:HH24:MI:SS')},
    '_ts2char should work';

ok my $dtfunc = $CLASS->can('_dt'), "$CLASS->can('_dt')";
isa_ok my $dt = $dtfunc->(
    'year:2012:month:07:day:05:hour:15:minute:07:second:01:time_zone:UTC'
), 'App::Sqitch::DateTime', 'Return value of _dt()';
is $dt->year, 2012, 'DateTime year should be set';
is $dt->month,   7, 'DateTime month should be set';
is $dt->day,     5, 'DateTime day should be set';
is $dt->hour,   15, 'DateTime hour should be set';
is $dt->minute,  7, 'DateTime minute should be set';
is $dt->second,  1, 'DateTime second should be set';
is $dt->time_zone->name, 'UTC', 'DateTime TZ should be set';

##############################################################################
# Can we do live tests?
my $dbh;
END {
    return unless $dbh;
    $dbh->{Driver}->visit_child_handles(sub {
        my $h = shift;
        $h->disconnect if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
    });

    $dbh->{RaiseError} = 0;
    $dbh->{PrintError} = 1;
    $dbh->do($_) for (
        'DROP TABLE IF EXISTS events',
        'DROP TABLE IF EXISTS dependencies',
        'DROP TABLE IF EXISTS tags',
        'DROP TABLE IF EXISTS changes',
        'DROP TABLE IF EXISTS projects',
    );
}

my $pass = $ENV{CUBPASS} || '';

my $err = try {
    my $dsn = "dbi:cubrid:database=__sqitchtest__";
    $dbh = DBI->connect($dsn, 'dba', $pass, {
        PrintError => 0,
        RaiseError => 1,
        AutoCommit => 1,
    });
    undef;
} catch {
    eval { $_->message } || $_;
};

DBIEngineTest->run(
    class         => $CLASS,
    sqitch_params => [
        db_username => 'dba',
        db_name     => '__sqitchtest__',
        top_dir     => Path::Class::dir(qw(t engine)),
        plan_file   => Path::Class::file(qw(t engine sqitch.plan)),
    ],
    engine_params     => [ password => $pass, sqitch_db => '__metasqitch' ],
    alt_engine_params => [ password => $pass, sqitch_db => '__sqitchtest' ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have csql and can connect to the database.
        # The version message is sent to STDERR
        # $self->sqitch->probe( $self->client, '--version' );
        # $self->_capture('--version'); # capture doesn't work
        $self->_capture('--command' => 'SELECT version()');
    },
    engine_err_regex  => qr/^ERROR:/,
    init_error        =>  __x(
        'Sqitch database {database} already initialized',
        database => '__sqitchtest',
    ),
    add_second_format => q{date_add(%s, interval 1 second)},
    # test_dbh => sub {
    #     my $dbh = shift;
    #     # Check the session configuration.
    #     for my $spec (
    #         [group_concat_max_len => 32768],
    #     ) {
    #         # How can you get CUBRID system parameters using SQL ? Not yet :(
    #         # http://www.cubrid.org/questions/432659
    #         # is $dbh->selectcol_arrayref('SELECT @SESSION.' . $spec->[0])->[0],
    #         #     $spec->[1], "Setting $spec->[0] should be set to $spec->[1]";
    #     }
    # },
);

done_testing;
