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
    sqitch_db => 'any',
    db_name   => 'any',
    host      => 'any',
    port      => 'int',
], 'config_vars should return 7 vars';

my $sqitch = App::Sqitch->new;
isa_ok my $cub = $CLASS->new(sqitch => $sqitch, db_name => 'foodb'), $CLASS;

my $client = 'csql' . ($^O eq 'MSWin32' ? '.exe' : '');
is $cub->client, $client, 'client should default to csql';
is $cub->db_name, 'foodb', 'db_name should be required';
is $cub->destination, $cub->db_name,
    'Destination should be same as db_name';
is $cub->sqitch_db, 'sqitchmeta',
    "sqitch_db should default to 'sqitchmeta'";
# is $cub->meta_destination, $cub->sqitch_db,
#     'Meta destination should be same as sqitch_db';

my @std_opts = (
    '--CS-mode',
    '--single-line',
    '--no-pager',
);
is_deeply [$cub->csql], [$client, @std_opts],
    'csql command should connect to /nolog';

# is $cub->_script, join( "\n" => (
#         'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
#         'WHENEVER OSERROR EXIT 9;',
#         'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
#         'connect ',
# ) ), '_script should work';

# Set up username, password, and db_name.
isa_ok $cub = $CLASS->new(
    sqitch => $sqitch,
    username => 'fred',
    password => 'derf',
    db_name  => 'blah',
), $CLASS;

# Add a host name.
isa_ok $cub = $CLASS->new(
    sqitch => $sqitch,
    username => 'fred',
    password => 'derf',
    db_name  => 'blah',
    host     => 'there',
), $CLASS;

# Add a port and varibles.
isa_ok $cub = $CLASS->new(
    sqitch => $sqitch,
    username => 'fred',
    password => 'derf "derf"',
    db_name  => 'blah "blah"',
    host     => 'there',
    port     => 1345,
), $CLASS;
ok $cub->set_variables(foo => 'baz', whu => 'hi there', yo => q{"stellar"}),
    'Set some variables';

##############################################################################
# Test other configs for the destination.
#ENV: {
    # Make sure we override system-set vars.
    # local $ENV{CUBRIDDATABASE};
    # local $ENV{CUBRIDUSER};
    # for my $env (qw(CUBRIDDATABASE CUBRIDUSER)) {
    #     my $pg = $CLASS->new(sqitch => $sqitch);
    #     local $ENV{$env} = "\$ENV=whatever";
    #     is $pg->destination, "\$ENV=whatever", "Destination should read \$$env";
    #     is $pg->meta_destination, $pg->destination,
    #         'Meta destination should be the same as destination';
    # }

    # my $mocker = Test::MockModule->new('App::Sqitch');
    # $mocker->mock(sysuser => 'sysuser=whatever');
    # my $pg = $CLASS->new(sqitch => $sqitch);
    # is $pg->destination, 'sysuser=whatever',
    #     'Destination should fall back on sysuser';
    # is $pg->meta_destination, $pg->destination,
    #     'Meta destination should be the same as destination';

    # $pg = $CLASS->new(sqitch => $sqitch, username => 'hi');
    # is $pg->destination, 'hi', 'Destination should read username';
    # is $pg->meta_destination, $pg->destination,
    #     'Meta destination should be the same as destination';

    # $ENV{CUBDATABASE} = 'mydb';
    # $pg = $CLASS->new(sqitch => $sqitch, username => 'hi');
    # is $pg->destination, 'mydb', 'Destination should prefer $CUBRIDDATABASE to username';
    # is $pg->meta_destination, $pg->destination,
    #     'Meta destination should be the same as destination';
#}

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.cubrid.client'        => '/path/to/csql',
    'core.cubrid.user'          => 'freddy',
    'core.cubrid.password'      => 's3cr3t',
    'core.cubrid.db_name'       => 'widgets',
    'core.cubrid.host'          => 'db.example.com',
    'core.cubrid.port'          => 1234,
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $cub = $CLASS->new(sqitch => $sqitch), 'Create another ora';

is $cub->client, '/path/to/csql', 'client should be as configured';
is $cub->user, 'freddy', 'username should be as configured';
is $cub->password, 's3cr3t', 'password should be as configured';
is $cub->db_name, 'widgets', 'db_name should be as configured';
is $cub->destination, 'widgets', 'destination should default to db_name';
is $cub->meta_destination, 'widgets', 'meta_destination should default to db_name';
is $cub->host, 'db.example.com', 'host should be as configured';
is $cub->port, 1234, 'port should be as configured';
# is $cub->sqitch_schema, 'meta', 'sqitch_schema should be as configured';
is_deeply [$cub->csql], ['/path/to/csql', @std_opts],
    'csql command should be configured';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    db_client   => '/some/other/csql',
    db_username => 'anna',
    db_name     => 'widgets_dev',
    db_host     => 'foo.com',
    db_port     => 98760,
);

ok $cub = $CLASS->new(sqitch => $sqitch), 'Create a ora with sqitch with options';

# is $cub->client, '/some/other/csql', 'client should be as optioned';
is $cub->user, 'anna', 'username should be as optioned';
is $cub->password, 's3cr3t', 'password should still be as configured';
is $cub->db_name, 'widgets_dev', 'db_name should be as optioned';
is $cub->destination, 'widgets_dev', 'destination should still default to db_name';
is $cub->meta_destination, 'widgets_dev', 'meta_destination should still default to db_name';
is $cub->host, 'foo.com', 'host should be as optioned';
is $cub->port, 98760, 'port should be as optioned';
# is_deeply [$cub->csql], ['/some/other/csql', @std_opts],
#     'csql command should be as optioned';

##############################################################################
# Test _run() and _capture().
can_ok $cub, qw(_run _capture);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@capture, @spool);
$mock_sqitch->mock(spool   => sub { shift; @spool = @_ });
my $mock_run3 = Test::MockModule->new('IPC::Run3');
$mock_run3->mock(run3 => sub { @capture = @_ });

ok $cub->_run(qw(foo bar baz)), 'Call _run';
my $fh = shift @spool;
is_deeply \@spool, [$cub->csql],
    'Csql command should be passed to spool()';

is join('', <$fh> ), $cub->_script(qw(foo bar baz)),
    'The script should be spooled';

ok $cub->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [[$cub->csql], \$cub->_script(qw(foo bar baz)), []],
    'Command and script should be passed to run3()';

# Let's make sure that IPC::Run3 actually works as expected.
$mock_run3->unmock_all;
my $echo = Path::Class::file(qw(t echo.pl));
my $mock_ora = Test::MockModule->new($CLASS);
$mock_ora->mock(csql => sub { $^X, $echo, qw(hi there) });

is join (', ' => $cub->_capture(qw(foo bar baz))), "hi there\n",
    '_capture should actually capture';

# Make it die.
my $die = Path::Class::file(qw(t die.pl));
$mock_ora->mock(csql => sub { $^X, $die, qw(hi there) });
like capture_stderr {
    throws_ok {
        $cub->_capture('whatever'),
    } 'App::Sqitch::X', '_capture should die when csql dies';
}, qr/^OMGWTF/, 'STDERR should be emitted by _capture';

##############################################################################
# Test file and handle running.
my @run;
$mock_ora->mock(_run => sub {shift; @run = @_ });
ok $cub->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, ['@"foo/bar.sql"'],
    'File should be passed to run()';

ok $cub->run_file('foo/"bar".sql'), 'Run foo/"bar".sql';
is_deeply \@run, ['@"foo/""bar"".sql"'],
    'Double quotes in file passed to run() should be escaped';

ok $cub->run_handle('FH'), 'Spool a "file handle"';
my $handles = shift @spool;
is_deeply \@spool, [$cub->csql],
    'csql command should be passed to spool()';
isa_ok $handles, 'ARRAY', 'Array ove handles should be passed to spool';
$fh = $handles->[0];
is join('', <$fh>), $cub->_script, 'First file handle should be script';
is $handles->[1], 'FH', 'Second should be the passed handle';

# Verify should go to capture unless verosity is > 1.
$mock_ora->mock(_capture => sub {shift; @capture = @_ });
ok $cub->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, ['@"foo/bar.sql"'],
    'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $cub->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, ['@"foo/bar.sql"'],
    'Verifile file should be passed to run() for high verbosity';

$mock_sqitch->unmock_all;
$mock_config->unmock_all;
$mock_ora->unmock_all;

##############################################################################
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
if ($^O eq 'MSWin32' && eval { require Win32::API}) {
    # Call kernel32.SetErrorMode(SEM_FAILCRITICALERRORS):
    # "The system does not display the critical-error-handler message box.
    # Instead, the system sends the error to the calling process." and
    # "A child process inherits the error mode of its parent process."
    my $SetErrorMode = Win32::API->new('kernel32', 'SetErrorMode', 'I', 'I');
    my $SEM_FAILCRITICALERRORS = 0x0001;
    $SetErrorMode->Call($SEM_FAILCRITICALERRORS);
}
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
        'DROP TABLE events',
        'DROP TABLE dependencies',
        'DROP TABLE tags',
        'DROP TABLE changes',
        'DROP TABLE projects',
        'DROP TYPE  sqitch_array',
        'DROP TABLE oe.events',
        'DROP TABLE oe.dependencies',
        'DROP TABLE oe.tags',
        'DROP TABLE oe.changes',
        'DROP TABLE oe.projects',
        'DROP TYPE  oe.sqitch_array',
    );
}

my $user = $ENV{CUBRIDUSER} || 'dba';
my $pass = $ENV{CUBRIDPASS} || '';
my $err = try {
    my $dsn = 'dbi:Cubrid:';
    $dbh = DBI->connect($dsn, $user, $pass, {
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
    engine_params     => [],
    alt_engine_params => [ sqitch_schema => '__sqitchtest' ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have psql and can connect to the database.
        $self->sqitch->probe( $self->client, '--version' );
        $self->_capture('--command' => 'SELECT version()');
    },
    engine_err_regex  => qr/^ERROR:  /,
    init_error        => __x(
        'Sqitch schema "{schema}" already exists',
        schema => '__sqitchtest',
    ),
);

done_testing;
