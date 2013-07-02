# Notes:
#  Tested only with CUBRID 9.1, failed to install DBD::cubrid in v8.4.3
#  Differences from other engines:
#   Pg Array -> CUBRID SEQUENCE
#   CHANGE is a reserved word!: Col 'change' renamed to 'change_name'
#   csql doesn't have a '--quiet' option
#   No TIME ZONE in CUBRID, only plain TIMESTAMP type (v <= 9.1.0)

# Problems:
#  Some tests are disabled
#  Some tests fail
#  LOCK TABLE changes IN EXCLUSIVE MODE not implemented
#  Many other problems, probably :)

# Requirements for live testing:
# Databases:
# * sqitchmeta
# * sqitchtest
# * sqitchtest2
# Environment variables:
# * CUBUSER (optional, the default is 'dba')
# * CUBPASS

package App::Sqitch::Engine::cubrid;

use 5.010;
use Mouse;
use utf8;
use Path::Class;
use DBI;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use List::Util qw(first);
use namespace::autoclean;

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

has sqitch_db => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 1,
    #handles  => { meta_destination => 'stringify' },
    default  => sub {
        my $self = shift;
        if (my $db = $self->sqitch->config->get( key => 'core.cubrid.sqitch_db' ) ) {
            return $db;
        }
        # A default name here?
        return 'sqitchmeta';
    },
);

has db_name => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 1,
    #handles  => { destination => 'stringify' },
    default  => sub {
        my $self   = shift;
        my $sqitch = $self->sqitch;
        my $name = $sqitch->db_name
            || $self->sqitch->config->get( key => 'core.cubrid.db_name' )
            || try { $sqitch->plan->project }
            || return undef;
        return $name;
    },
);

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

has dbh => (
    is      => 'rw',
    isa     => 'DBI::db',
    lazy    => 1,
    default => sub {
        my $self = shift;
        try { require DBD::cubrid } catch {
            hurl cubrid => __ 'DBD::cubrid module required to manage CUBRID' if $@;
        };

        my $dsn = 'dbi:cubrid:' . join ';' => map {
            "$_->[0]=$_->[1]"
        } grep { $_->[1] } (
            [ database => $self->sqitch_db ],
            [ host     => $self->host      ],
            [ port     => $self->port      ],
        );

        my $user = $self->user ? $self->user : 'dba';

        DBI->connect($dsn, $user, $self->password, {
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
        });
    }
);

sub destination { shift->db_name; }        #???

sub meta_destination { shift->sqitch_db; } #???

sub config_vars {
    return (
        client    => 'any',
        user      => 'any',
        password  => 'any',
        sqitch_db => 'any',
        db_name   => 'any',
        host      => 'any',
        port      => 'int',
    );
}

sub _log_tags_param {
    my $str = join ',' => map { q{'} . $_->format_name . q{'} } $_[1]->tags;
    return "{$str}";
}

sub _log_requires_param {
    my $str = join ',' => map { q{'} . $_->as_string . q{'} } $_[1]->requires;
    return "{$str}";
}

sub _log_conflicts_param {
    my $str = join ',' => map { q{'} . $_->as_string . q{'} } $_[1]->conflicts;
    return "{$str}";
}

sub _ts2char_format {
    q{to_char(%1$s, '"year":YYYY:"month":MM:"day":DD') || to_char(%1$s, ':"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')}
}

sub _ts_default { 'current_timestamp' }

sub _char2ts {
    my $dt = $_[1];
    $dt->set_time_zone('UTC');
    return join ' ', $dt->ymd('-'), $dt->hms(':');
}

sub _listagg_format {
    q{CONCAT_WS(' ', %s)};
}

sub _regex_op { 'REGEXP(%s, ?)' }

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;
    return try {
        return $self->dbh->selectcol_arrayref(qq{
            SELECT change_id FROM (
                SELECT change_id, rownum as rnum FROM (
                    SELECT change_id
                      FROM changes
                     WHERE project = ?
                     ORDER BY committed_at $ord
                )
            ) WHERE rnum = ?
        }, undef, $project || $self->plan->project, ($offset // 0) + 1)->[0];
    } catch {
        return if $self->_no_table_error;
        die $_;
    };
}

# sub current_state {
#     my ( $self, $project ) = @_;
#     my $cdtcol = sprintf $self->_ts2char_format, 'c.committed_at';
#     my $pdtcol = sprintf $self->_ts2char_format, 'c.planned_at';
#     my $tagcol = sprintf $self->_listagg_format, 't.tag';
#     my $chgcol = $self->change_col;
#     my $dbh    = $self->dbh;
#     my $state  = $dbh->selectrow_hashref(qq{
#         SELECT c.change_id
#              , c.$chgcol AS [change]
#              , c.project
#              , c.note
#              , c.committer_name
#              , c.committer_email
#              , $cdtcol AS committed_at
#              , c.planner_name
#              , c.planner_email
#              , $pdtcol AS planned_at
#              , $tagcol AS tags
#           FROM changes   c
#           LEFT JOIN tags t ON c.change_id = t.change_id
#          WHERE c.project = ?
#          GROUP BY c.change_id
#              , $chgcol
#              , c.project
#              , c.note
#              , c.committer_name
#              , c.committer_email
#              , c.committed_at
#              , c.planner_name
#              , c.planner_email
#              , c.planned_at
#          ORDER BY c.committed_at DESC LIMIT 1
#     }, undef, $project // $self->plan->project ) or return undef;
#     unless (ref $state->{tags}) {
#         $state->{tags} = $state->{tags} ? [ split / / => $state->{tags} ] : [];
#     }
#     $state->{committed_at} = _dt $state->{committed_at};
#     $state->{planned_at}   = _dt $state->{planned_at};
#     return $state;
# }

# sub deployed_changes {
#     my $self   = shift;
#     my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
#     my $tagcol = sprintf $self->_listagg_format, 't.tag';
#     my $chgcol = $self->change_col;
#     return map {
#         $_->{timestamp} = _dt $_->{timestamp};
#         unless (ref $_->{tags}) {
#             $_->{tags} = $_->{tags} ? [ split / / => $_->{tags} ] : [];
#         }
#         $_;
#     } @{ $self->dbh->selectall_arrayref(qq{
#         SELECT c.change_id AS id, c.$chgcol AS name, c.project, c.note,
#                $tscol AS [timestamp], c.planner_name, c.planner_email,
#                $tagcol AS tags
#           FROM changes   c
#           LEFT JOIN tags t ON c.change_id = t.change_id
#          WHERE c.project = ?
#          GROUP BY c.change_id, c.$chgcol, c.project, c.note, c.planned_at,
#                c.planner_name, c.planner_email, c.committed_at
#          ORDER BY c.committed_at ASC
#     }, { Slice => {} }, $self->plan->project) };
# }

# sub load_change {
#     my ( $self, $change_id ) = @_;
#     my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
#     my $tagcol = sprintf $self->_listagg_format, 't.tag';
#     my $qcid   = $self->dbh->quote($change_id);
#     my $chgcol = $self->change_col;
#     my $change = $self->dbh->selectrow_hashref(qq{
#         SELECT c.change_id AS id, c.$chgcol AS name, c.project, c.note,
#                $tscol AS [timestamp], c.planner_name, c.planner_email,
#                 $tagcol AS tags
#           FROM changes   c
#           LEFT JOIN tags t ON c.change_id = t.change_id
#          WHERE c.change_id = $qcid
#          GROUP BY c.change_id, c.$chgcol, c.project, c.note, c.planned_at,
#                c.planner_name, c.planner_email
#     }, undef) || return undef;
#     $change->{timestamp} = _dt $change->{timestamp};
#     return $change;
# }

sub is_deployed_change {
    my ( $self, $change ) = @_;
    $self->dbh->selectcol_arrayref(
        q{SELECT 1 FROM changes WHERE change_id = ?},
        undef, $change->id
    )->[0];
}

sub initialized {
    my $self = shift;
    return $self->dbh->selectcol_arrayref(q{
         SELECT class_name
             FROM _db_class
             WHERE is_system_class = 0 AND class_name = ?;
    }, undef, 'changes')->[0];
}

# sub changes_requiring_change {
#     my ( $self, $change ) = @_;
#     my $chgcol = $self->change_col;
#     return @{ $self->dbh->selectall_arrayref(qq{
#         SELECT c.change_id, c.project, c.$chgcol AS [change], (
#             SELECT tag
#               FROM changes c2
#               JOIN tags ON c2.change_id = tags.change_id
#              WHERE c2.project = c.project
#                AND c2.committed_at >= c.committed_at
#              ORDER BY c2.committed_at
#              LIMIT 1
#         ) AS asof_tag
#           FROM dependencies d
#           JOIN changes c ON c.change_id = d.change_id
#          WHERE d.dependency_id = ?
#     }, { Slice => {} }, $change->id) };
# }

# sub name_for_change_id {
#     my ( $self, $change_id ) = @_;
#     my $chgcol = $self->change_col;
#     return $self->dbh->selectcol_arrayref(q{
#         SELECT $chgcol AS [change] || COALESCE((
#             SELECT tag
#               FROM changes c2
#               JOIN tags ON c2.change_id = tags.change_id
#              WHERE c2.committed_at >= c.committed_at
#                AND c2.project = c.project
#              LIMIT 1
#         ), '')
#           FROM changes c
#          WHERE change_id = ?
#     }, undef, $change_id)->[0];
# }

# sub change_offset_from_id {
#     my ( $self, $change_id, $offset ) = @_;

#     # Just return the object if there is no offset.
#     return $self->load_change($change_id) unless $offset;

#     # Are we offset forwards or backwards?
#     my ( $dir, $op ) = $offset > 0 ? ( 'ASC', '>' ) : ( 'DESC' , '<' );
#     my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
#     my $tagcol = sprintf $self->_listagg_format, 't.tag';

#     my $chgcol = $self->change_col;

#     # SQLite and CUBRID requires LIMIT when there is an OFFSET.
#     # The OFFSET feature in CUBRID is from v9.0
#     my $limit  = '';
#     if (my $lim = $self->_limit_default) {
#         $limit = "LIMIT $lim ";
#     }
#     my $change = $self->dbh->selectrow_hashref(qq{
#         SELECT c.change_id AS id, c.$chgcol AS name, c.project, c.note,
#                $tscol AS timestamp, c.planner_name, c.planner_email,
#                $tagcol AS tags
#           FROM changes   c
#           LEFT JOIN tags t ON c.change_id = t.change_id
#          WHERE c.project = ?
#            AND c.committed_at $op (
#                SELECT committed_at FROM changes WHERE change_id = ?
#          )
#          GROUP BY c.change_id, c.$chgcol, c.project, c.note, c.planned_at,
#                c.planner_name, c.planner_email, c.committed_at
#          ORDER BY c.committed_at $dir
#          ${limit}OFFSET ?
#     }, undef, $self->plan->project, $change_id, abs($offset) - 1) || return undef;
#     $change->{timestamp} = _dt $change->{timestamp};
#     unless (ref $change->{tags}) {
#         $change->{tags} = $change->{tags} ? [ split / / => $change->{tags} ] : [];
#     }
#     return $change;
# }

sub is_deployed_tag {
    my ( $self, $tag ) = @_;
    return $self->dbh->selectcol_arrayref(
        q{SELECT 1 FROM tags WHERE tag_id = ?},
        undef, $tag->id
    )->[0];
}

sub initialize {
    my $self   = shift;
    hurl engine => __x(
        'Sqitch database {database} already initialized',
        database => $self->sqitch_db,
    ) if $self->initialized;

    # Load up our database.
    my @cmd = $self->csql;
    $cmd[-1] = $self->sqitch_db;
    my $file = file(__FILE__)->dir->file('cubrid.sql');
    $self->sqitch->run( @cmd, '--input-file' => $file );
}

# sub search_events {
#     my ( $self, %p ) = @_;

#     # Determine order direction.
#     my $dir = 'DESC';
#     if (my $d = delete $p{direction}) {
#         $dir = $d =~ /^ASC/i  ? 'ASC'
#              : $d =~ /^DESC/i ? 'DESC'
#              : hurl 'Search direction must be either "ASC" or "DESC"';
#     }

#     # Limit with regular expressions?
#     my (@wheres, @params);
#     my $op = $self->_regex_op;
#     for my $spec (
#         [ committer => 'committer_name' ],
#         [ planner   => 'planner_name'   ],
#         [ change    => 'change'         ],
#         [ project   => 'project'        ],
#     ) {
#         my $regex = delete $p{ $spec->[0] } // next;
#         push @wheres => "$spec->[1] $op ?";
#         push @params => $regex;
#     }

#     # Match events?
#     if (my $e = delete $p{event} ) {
#         my ($in, @vals) = $self->_in_expr( $e );
#         push @wheres => "event $in";
#         push @params => @vals;
#     }

#     # Assemble the where clause.
#     my $where = @wheres
#         ? "\n         WHERE " . join( "\n               ", @wheres )
#         : '';

#     # Handle remaining parameters.
#     my $limits = '';
#     if (exists $p{limit} || exists $p{offset}) {
#         my $lim = delete $p{limit};
#         if ($lim) {
#             $limits = "\n         LIMIT ?";
#             push @params => $lim;
#         }
#         if (my $off = delete $p{offset}) {
#             if (!$lim && ($lim = $self->_limit_default)) {
#                 # SQLite requires LIMIT when OFFSET is set.
#                 $limits = "\n         LIMIT ?";
#                 push @params => $lim;
#             }
#             $limits .= "\n         OFFSET ?";
#             push @params => $off;
#         }
#     }

#     hurl 'Invalid parameters passed to search_events(): '
#         . join ', ', sort keys %p if %p;

#     # Prepare, execute, and return.
#     my $cdtcol = sprintf $self->_ts2char_format, 'committed_at';
#     my $pdtcol = sprintf $self->_ts2char_format, 'planned_at';
#     my $chgcol = $self->change_col;
#     my $sth = $self->dbh->prepare(qq{
#         SELECT event
#              , project
#              , change_id
#              , $chgcol AS [change]
#              , note
#              , requires
#              , conflicts
#              , tags
#              , committer_name
#              , committer_email
#              , $cdtcol AS committed_at
#              , planner_name
#              , planner_email
#              , $pdtcol AS planned_at
#           FROM events$where
#          ORDER BY events.committed_at $dir$limits
#     });
#     $sth->execute(@params);
#     return sub {
#         my $row = $sth->fetchrow_hashref or return;
#         $row->{committed_at} = _dt $row->{committed_at};
#         $row->{planned_at}   = _dt $row->{planned_at};
#         return $row;
#     };
# }

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

# sub log_deploy_change {
#     my ($self, $change) = @_;
#     my $dbh    = $self->dbh;
#     my $sqitch = $self->sqitch;
#     my $chgcol = $self->change_col;

#     my ($id, $name, $proj, $user, $email) = (
#         $change->id,
#         $change->format_name,
#         $change->project,
#         $sqitch->user_name,
#         $sqitch->user_email
#     );

#     my $ts = $self->_ts_default;
#     $dbh->do(qq{
#         INSERT INTO changes (
#               change_id
#             , $chgcol
#             , project
#             , note
#             , committer_name
#             , committer_email
#             , planned_at
#             , planner_name
#             , planner_email
#             , committed_at
#         )
#         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, $ts)
#     }, undef,
#         $id,
#         $name,
#         $proj,
#         $change->note,
#         $user,
#         $email,
#         $self->_char2ts( $change->timestamp ),
#         $change->planner_name,
#         $change->planner_email,
#     );

#     if ( my @deps = $change->dependencies ) {
#         $dbh->do(q{
#             INSERT INTO dependencies(
#                   change_id
#                 , type
#                 , dependency
#                 , dependency_id
#            ) } . $self->_multi_values(scalar @deps, '?, ?, ?, ?'),
#             undef,
#             map { (
#                 $id,
#                 $_->type,
#                 $_->as_string,
#                 $_->resolved_id,
#             ) } @deps
#         );
#     }

#     if ( my @tags = $change->tags ) {
#         $dbh->do(q{
#             INSERT INTO tags (
#                   tag_id
#                 , tag
#                 , project
#                 , change_id
#                 , note
#                 , committer_name
#                 , committer_email
#                 , planned_at
#                 , planner_name
#                 , planner_email
#                 , committed_at
#            ) } . $self->_multi_values(scalar @tags, "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, $ts"),
#             undef,
#             map { (
#                 $_->id,
#                 $_->format_name,
#                 $proj,
#                 $id,
#                 $_->note,
#                 $user,
#                 $email,
#                 $self->_char2ts( $_->timestamp ),
#                 $_->planner_name,
#                 $_->planner_email,
#             ) } @tags
#         );
#     }

#     return $self->_log_event( deploy => $change );
# }

sub _log_event {
    my ( $self, $event, $change, $tags, $requires, $conflicts) = @_;

    # Can insert SEQUENCE with parameters? Not yet ;)
    # http://www.cubrid.org/home_page/677557
    # CUBRID DBMS Error : (-494) Semantic: Cannot coerce host var to type
    # sequence.  at ... line ...
    my $tg = $tags      || $self->_log_tags_param($change);
    my $rq = $requires  || $self->_log_requires_param($change);
    my $cf = $conflicts || $self->_log_conflicts_param($change);
    my $dbh    = $self->dbh;
    my $sqitch = $self->sqitch;

    my $ts = $self->_ts_default;

    $dbh->do(qq{
        INSERT INTO events (
              event
            , change_id
            , "change"
            , project
            , note
            , tags
            , requires
            , conflicts
            , committer_name
            , committer_email
            , planned_at
            , planner_name
            , planner_email
            , committed_at
        )
        VALUES (?, ?, ?, ?, ?, $tg, $rq, $cf, ?, ?, ?, ?, ?, $ts)
    }, undef,
        $event,
        $change->id,
        $change->name,
        $change->project,
        $change->note,
        $sqitch->user_name,
        $sqitch->user_email,
        $self->_char2ts( $change->timestamp ),
        $change->planner_name,
        $change->planner_email,
    );

    return $self;
}

sub _ts2char($) {
    my $col = shift;
    return qq{to_char($col AT TIME ZONE 'UTC', 'YYYY:MM:DD:HH24:MI:SS')};
}

sub _no_table_error  {
    return defined $DBI::err && $DBI::err == -20001; # a generic error?
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
