# Notes:
#  Tested only with CUBRID 9.1, failed to install DBD::cubrid in v8.4.3
#  Differences from other engines:
#   Pg Array -> CUBRID SEQUENCE
#   CHANGE is a reserved word!: Col 'change' renamed to 'change_name'
#   csql doesn't have a '--quiet' option
#   No TIME ZONE in CUBRID, only plain TIMESTAMP type (v <= 9.1.0)

# Problems:
#  Some tests fail
#  LOCK TABLE changes IN EXCLUSIVE MODE not implemented
#  Many other problems, probably :)

# Requirements for live testing:
# Databases:
# * __sqitchtest__
# * __metasqitch
# * __sqitchtest
# Environment variables:
# * CUBPASS

package App::Sqitch::Engine::cubrid;

use 5.010;
use strict;
use warnings;
use utf8;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use Path::Class;
use Mouse;
use namespace::autoclean;
use Sort::Versions;

extends 'App::Sqitch::Engine';
sub dbh; # required by DBIEngine;
with 'App::Sqitch::Role::DBIEngine';

our $VERSION = '0.973';

has client => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_client
            || $sqitch->config->get( key => 'core.cubrid.client' )
            || 'csql' . ( $^O eq 'MSWin32' ? '.exe' : '' );
    },
);

has user => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_username || $sqitch->config->get( key => 'core.cubrid.user' );
    },
);

has password => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        shift->sqitch->config->get( key => 'core.cubrid.password' );
    },
);

has db_name => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $self   = shift;
        my $sqitch = $self->sqitch;
        $sqitch->db_name || $sqitch->config->get( key => 'core.cubrid.db_name' );
    },
);

sub destination { shift->db_name }

has sqitch_db => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 1,
    default  => sub {
        shift->sqitch->config->get( key => 'core.cubrid.sqitch_db' ) || 'sqitch';
    },
);

sub meta_destination { shift->sqitch_db }

has host => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_host || $sqitch->config->get( key => 'core.cubrid.host' );
    },
);

has port => (
    is       => 'ro',
    isa      => 'Maybe[Int]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_port || $sqitch->config->get( key => 'core.cubrid.port' );
    },
);

has dbh => (
    is      => 'rw',
    isa     => 'DBI::db',
    lazy    => 1,
    default => sub {
        my $self = shift;
        try { require DBD::cubrid } catch {
            hurl cubrid => __ 'DBD::cubrid module required to manage CUBRID' if $@;
        };

        my $dsn = 'dbi:cubrid:database=' . ($self->sqitch_db || hurl cubrid => __(
            'No database specified; use --db-name or set "core.cubrid.db_name" via sqitch config'
        ));

        my $dbh = DBI->connect($dsn, $self->user, $self->password, {
            PrintError        => 0,
            RaiseError        => 0,
            AutoCommit        => 1,
            FetchHashKeyName  => 'NAME_lc',
            HandleError       => sub {
                my ($err, $dbh) = @_;
                $@ = $err;
                @_ = ($dbh->state || 'DEV' => $dbh->errstr);
                goto &hurl;
            },
            Callbacks             => {
                connected => sub {
                    my $dbh = shift;
                    # This currently doesn't work:
                    # http://www.cubrid.org/forum/694738
                    #
                    # http://www.cubrid.org/manual/91/en/admin/config.html#cubrid-conf-default-parameters
                    # TODO: Understand this parameters:
                    # unicode_input_normalization  no
                    # unicode_output_normalization no
                    #
                    # DATE | DATETIME | TIMESTAMP allows 0000-00-00
                    # No setting to change this :(
                    $dbh->do("SET SYSTEM PARAMETERS $_") for (
                        q{group_concat_max_len=32768},
                    );
                    return;
                },
            },
        });
        # Make sure we support this version.
        my $want_version = '9.1.0';
        my $have_version = $dbh->selectcol_arrayref('SELECT version()')->[0];

        hurl cubrid => __x(
            'Sqitch requires CUBRID {want_version} or higher; this is {have_version}',
            want_version => $want_version,
            have_version => $have_version,
        ) unless versioncmp($want_version, $have_version) == -1;

        return $dbh;
    }
);

has csql => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy       => 1,
    required   => 1,
    auto_deref => 1,
    default    => sub {
        my $self = shift;
        my @ret  = ( $self->client );
        for my $spec (
            [ user     => $self->user     ],
            [ password => $self->password ],
            )
        {
            push @ret, "--$spec->[0]" => $spec->[1] if $spec->[1];
        }

        push @ret => (
            '--CS-mode',
            '--single-line',
            '--no-pager',
        );

        # csql [options] database_name@remote_host_name
        # There is no port option!, "the port number used by the
        # master process on the remote host must be identical to the
        # one on the local host"
        my $db_name = '';
        if ( $self->db_name ) {
            $db_name = $self->db_name;
            $db_name .= '@' . $self->host
                if $self->host;
            push @ret, $db_name;
        }
        return \@ret;
    },
);

sub config_vars {
    return (
        client    => 'any',
        user      => 'any',
        password  => 'any',
        db_name   => 'any',
        host      => 'any',
        port      => 'int',
        sqitch_db => 'any',
    );
}

sub _char2ts {
    my $dt = $_[1];
    $dt->set_time_zone('UTC');
    return join ' ', $dt->ymd('-'), $dt->hms(':');
}

sub _ts2char_format {
    q{to_char(%1$s, '"year":YYYY:"month":MM:"day":DD') || to_char(%1$s, ':"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')}
}

sub _ts_default { 'CURRENT_DATETIME' }

sub _quote_idents {
    shift;
    map { $_ eq 'change' ? '"change"' : $_ } @_;
}

sub initialized {
    my $self = shift;

    # Try to connect.
    my $err = 0;
    my $dbh = try { $self->dbh } catch { $err = $DBI::err };
    # CUBRID error code ??? : Unknown database '%-.192s'  ???
    return 0 if $err; # && $err == 1049;

    return $self->dbh->selectcol_arrayref(q{
         SELECT class_name
             FROM _db_class
             WHERE is_system_class = 0 AND class_name = ?;
    }, undef, 'changes')->[0];
}

sub initialize {
    my $self   = shift;
    hurl engine => __x(
        'Sqitch database {database} already initialized',
        database => $self->sqitch_db,
    ) if $self->initialized;

    # Load up our database. The database have to exist!
    my @cmd = $self->csql;
    $cmd[-1] = $self->sqitch_db;
    my $file = file(__FILE__)->dir->file('cubrid.sql');
    $self->sqitch->run( @cmd, '--input-file' => $file );
}

# Override to lock the changes table. This ensures that only one instance of
# Sqitch runs at one time.
sub begin_work {
    my $self = shift;
    my $dbh = $self->dbh;

    # Start transaction and lock changes to allow only one change at a time.
    $dbh->begin_work;
    #$dbh->do('LOCK TABLE changes IN EXCLUSIVE MODE');??? howto ???
    return $self;
}

sub _no_table_error  {
    return $DBI::errstr =~ /Unknown class/;
}

sub _regex_op { 'REGEXP' }

sub _limit_default { '33554432' } # MySQL: '18446744073709551615'

sub _listagg_format {
    return q{group_concat(%s SEPARATOR ' ')};
}

sub _run {
    my $self   = shift;
    return $self->sqitch->run( $self->csql, @_ );
}

sub _capture {
    my $self   = shift;
    return $self->sqitch->capture( $self->csql, @_ );
}

sub _spool {
    my $self   = shift;
    my $fh     = shift;
    return $self->sqitch->spool( $fh, $self->csql, @_ );
}

sub run_file {
    my ($self, $file) = @_;
    $self->_run('--input-file' => $file);
}

sub run_verify {
    my ($self, $file) = @_;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    $self->$meth( '--input-file' => $file );
}

sub run_handle {
    my ($self, $fh) = @_;
    $self->_spool($fh);
}

sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;

    my $offexpr = $offset ? " OFFSET $offset" : '';
    return try {
        return $self->dbh->selectcol_arrayref(qq{
            SELECT change_id
              FROM changes
             WHERE project = ?
             ORDER BY committed_at $ord
             LIMIT 1$offexpr
        }, undef, $project || $self->plan->project)->[0];
    } catch {
        return if $self->_no_table_error;
        die $_;
    };
}

# sub _log_tags_param {
#     [ map { $_->format_name } $_[1]->tags ];
# }

# sub _log_requires_param {
#     [ map { $_->as_string } $_[1]->requires ];
# }

# sub _log_conflicts_param {
#     [ map { $_->as_string } $_[1]->conflicts ];
# }

sub is_deployed_change {
    my ( $self, $change ) = @_;
    $self->dbh->selectcol_arrayref(
        q{SELECT 1 FROM changes WHERE change_id = ?},
        undef, $change->id
    )->[0];
}

sub is_deployed_tag {
    my ( $self, $tag ) = @_;
    return $self->dbh->selectcol_arrayref(
        q{SELECT 1 FROM tags WHERE tag_id = ?},
        undef, $tag->id
    )->[0];
}

# sub _log_event {
#     my ( $self, $event, $change, $tags, $requires, $conflicts) = @_;

#     # Can insert SEQUENCE with parameters? Not yet ;)
#     # http://www.cubrid.org/home_page/677557
#     # CUBRID DBMS Error : (-494) Semantic: Cannot coerce host var to type
#     # sequence.  at ... line ...

#     my $tg = $tags      || $self->_log_tags_param($change);
#     my $rq = $requires  || $self->_log_requires_param($change);
#     my $cf = $conflicts || $self->_log_conflicts_param($change);
#     my $dbh    = $self->dbh;
#     my $sqitch = $self->sqitch;

#     my $ts = $self->_ts_default;

#     $dbh->do(qq{
#         INSERT INTO events (
#               event
#             , change_id
#             , "change"
#             , project
#             , note
#             , tags
#             , requires
#             , conflicts
#             , committer_name
#             , committer_email
#             , planned_at
#             , planner_name
#             , planner_email
#             , committed_at
#         )
#         VALUES (?, ?, ?, ?, ?, $tg, $rq, $cf, ?, ?, ?, ?, ?, $ts)
#     }, undef,
#         $event,
#         $change->id,
#         $change->name,
#         $change->project,
#         $change->note,
#         $sqitch->user_name,
#         $sqitch->user_email,
#         $self->_char2ts( $change->timestamp ),
#         $change->planner_name,
#         $change->planner_email,
#     );

#     return $self;
# }

sub _ts2char($) {
    my $col = shift;
    return qq{to_char($col AT TIME ZONE 'UTC', 'YYYY:MM:DD:HH24:MI:SS')};
}

__PACKAGE__->meta->make_immutable;
no Mouse;

__END__

=head1 Name

App::Sqitch::Engine::cubrid - Sqitch CUBRID Engine

=head1 Synopsis

  my $cubrid = App::Sqitch::Engine->load( engine => 'cubrid' );

=head1 Description

App::Sqitch::Engine::cubrid provides the CUBRID storage engine for Sqitch.

=head1 Interface

=head3 Class Methods

=head3 C<config_vars>

  my %vars = App::Sqitch::Engine::cubrid->config_vars;

Returns a hash of names and types to use for variables in the C<core.cubrid>
section of the a Sqitch configuration file. The variables and their types are:

  client    => 'any'
  db_name   => 'any'
  sqitch_db => 'any'

=head2 Accessors

=head3 C<client>

Returns the path to the CUBRID client. If C<--db-client> was passed to
C<sqitch>, that's what will be returned. Otherwise, it uses the
C<core.cubrid.client> configuration value, or else defaults to C<csql> (or
C<csql.exe> on Windows), which should work if it's in your path.

=head3 C<db_name>

Returns the name of the database file. If C<--db-name> was passed to C<sqitch>
that's what will be returned.

=head3 C<sqitch_db>

Name of the CUBRID database file to use for the Sqitch metadata tables.
Returns the value of the C<core.cubrid.sqitch_db> configuration value, or else
defaults to F<sqitch.db> in the same directory as C<db_name>.

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2013 iovation Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut
