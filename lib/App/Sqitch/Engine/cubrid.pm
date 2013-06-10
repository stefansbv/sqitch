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

use Data::Printer;

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
        # A default name?
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

has destination => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $self = shift;
        $self->db_name
            # || $ENV{CUBDATABASE}
            # || $self->username
            # || $ENV{CUBUSER}
            # || $self->sqitch->sysuser
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
        [ $self->client, qw( --CS-mode --single-line --no-pager) ];
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
            [ database => $self->db_name  ],
            [ host     => $self->host     ],
            [ port     => $self->port     ],
        );
        print "DSN: $dsn\n";
        my $user = $self->user ? $self->user : 'dba';

        DBI->connect($dsn, $user, $self->password, {
            PrintError        => 0,
            RaiseError        => 0,
            AutoCommit        => 1,
            HandleError       => sub {
                my ($err, $dbh) = @_;
                $@ = $err;
                @_ = ($dbh->state || 'DEV' => $dbh->errstr);
                goto &hurl;
            },
            # Callbacks         => {
            #     connected => sub {
            #         my $dbh = shift;
            #         $dbh->do('PRAGMA foreign_keys = ON');
            #         return;
            #     },
            # },
        });
    }
);

sub config_vars {
    return (
        client   => 'any',
        user     => 'any',
        password => 'any',
        sqitch_db => 'any',
        db_name  => 'any',
        host     => 'any',
        port     => 'int',
    );
}

sub _log_tags_param {
    [ map { $_->format_name } $_[1]->tags ];
}

sub _log_requires_param {
    [ map { $_->as_string } $_[1]->requires ];
}

sub _log_conflicts_param {
    [ map { $_->as_string } $_[1]->conflicts ];
}

sub _ts2char_format {
    q{to_char(%1$s AT TIME ZONE 'UTC', '"year":YYYY:"month":MM:"day":DD') || to_char(%1$s AT TIME ZONE 'UTC', ':"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')}
}

sub _ts_default { 'current_timestamp' }

sub _char2ts {
    my $dt = $_[1];
    join ' ', $dt->ymd('-'), $dt->hms(':'), $dt->time_zone->name;
}

sub _listagg_format {
    # http://stackoverflow.com/q/16313631/79202
    return q{COLLECT(%s)};
}

sub _regex_op { 'REGEXP_LIKE(%s, ?)' }

sub _simple_from { ' FROM dual' }

sub _multi_values {
    my ($self, $count, $expr) = @_;
    return join "\nUNION ALL ", ("SELECT $expr FROM dual") x $count;
}

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;

    # my $config = App::Sqitch::Config->new;
    # say scalar $config->dump;

    print 'Sqitch is ', $self->initialized ? ' YES ' : ' NOT ', 'initialized', "\n";
    print "ord is $ord\n";
    print "offset is $offset\n";
    print "project is $project\n";

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

sub _cid_head {
    my ($self, $project, $change) = @_;
    return $self->dbh->selectcol_arrayref(qq{
        SELECT change_id FROM (
            SELECT change_id
              FROM changes
             WHERE project = ?
               AND change  = ?
             ORDER BY committed_at DESC
        ) WHERE rownum = 1
    }, undef, $project, $change)->[0];
}

sub current_state {
    my ( $self, $project ) = @_;
    my $cdtcol = sprintf $self->_ts2char_format, 'c.committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    my $dbh    = $self->dbh;
    # XXX Oy, placeholders do not work with COLLECT() in this query.
    # http://www.nntp.perl.org/group/perl.dbi.users/2013/05/msg36581.html
    # http://stackoverflow.com/q/16407560/79202
    my $qproj  = $dbh->quote($project // $self->plan->project);
    my $state  = $dbh->selectrow_hashref(qq{
        SELECT * FROM (
            SELECT c.change_id
                 , c.change
                 , c.project
                 , c.note
                 , c.committer_name
                 , c.committer_email
                 , $cdtcol AS committed_at
                 , c.planner_name
                 , c.planner_email
                 , $pdtcol AS planned_at
                 , $tagcol AS tags
              FROM changes   c
              LEFT JOIN tags t ON c.change_id = t.change_id
             WHERE c.project = $qproj
             GROUP BY c.change_id
                 , c.change
                 , c.project
                 , c.note
                 , c.committer_name
                 , c.committer_email
                 , c.committed_at
                 , c.planner_name
                 , c.planner_email
                 , c.planned_at
             ORDER BY c.committed_at DESC
        ) WHERE rownum = 1
    }) or return undef;
    $state->{committed_at} = _dt $state->{committed_at};
    $state->{planned_at}   = _dt $state->{planned_at};
    return $state;
}

sub deployed_changes {
    my $self   = shift;
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    # XXX Oy, placeholders do not work with COLLECT() in this query.
    # http://www.nntp.perl.org/group/perl.dbi.users/2013/05/msg36581.html
    # http://stackoverflow.com/q/16407560/79202
    my $qproj  = $self->dbh->quote($self->plan->project);
    return map {
        $_->{timestamp} = _dt $_->{timestamp};
        $_;
    } @{ $self->dbh->selectall_arrayref(qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note,
               $tscol AS timestamp, c.planner_name, c.planner_email,
               $tagcol AS tags
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.project = $qproj
         GROUP BY c.change_id, c.change, c.project, c.note, c.planned_at,
               c.planner_name, c.planner_email, c.committed_at
         ORDER BY c.committed_at ASC
    }, { Slice => {} } ) };
}

sub deployed_changes_since {
    my ( $self, $change ) = @_;
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    # XXX Oy, placeholders do not work with COLLECT() in this query.
    # http://www.nntp.perl.org/group/perl.dbi.users/2013/05/msg36581.html
    # http://stackoverflow.com/q/16407560/79202
    my $qproj  = $self->dbh->quote($self->plan->project);
    return map {
        $_->{timestamp} = _dt $_->{timestamp};
        $_;
    } @{ $self->dbh->selectall_arrayref(qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note,
               $tscol AS timestamp, c.planner_name, c.planner_email,
               $tagcol AS tags
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.project = $qproj
           AND c.committed_at > (SELECT committed_at FROM changes WHERE change_id = ?)
         GROUP BY c.change_id, c.change, c.project, c.note, c.planned_at,
               c.planner_name, c.planner_email, c.committed_at
         ORDER BY c.committed_at ASC
    }, { Slice => {} }, $change->id) };
}

sub load_change {
    my ( $self, $change_id ) = @_;
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    # XXX Oy, placeholders do not work with COLLECT() in this query.
    # http://www.nntp.perl.org/group/perl.dbi.users/2013/05/msg36581.html
    # http://stackoverflow.com/q/16407560/79202
    my $qcid   = $self->dbh->quote($change_id);
    my $change = $self->dbh->selectrow_hashref(qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note,
               $tscol AS timestamp, c.planner_name, c.planner_email,
                $tagcol AS tags
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.change_id = $qcid
         GROUP BY c.change_id, c.change, c.project, c.note, c.planned_at,
               c.planner_name, c.planner_email
    }, undef) || return undef;
    $change->{timestamp} = _dt $change->{timestamp};
    return $change;
}

sub is_deployed_change {
    my ( $self, $change ) = @_;
    $self->dbh->selectcol_arrayref(
        'SELECT 1 FROM changes WHERE change_id = ?',
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

sub _log_event {
    my ( $self, $event, $change, $tags, $requires, $conflicts) = @_;
    my $dbh    = $self->dbh;
    my $sqitch = $self->sqitch;

    $tags      ||= $self->_log_tags_param($change);
    $requires  ||= $self->_log_requires_param($change);
    $conflicts ||= $self->_log_conflicts_param($change);

    # Use the sqitch_array() constructor to insert arrays of values.
    my $tag_ph = 'sqitch_array('. join(', ', ('?') x @{ $tags      }) . ')';
    my $req_ph = 'sqitch_array('. join(', ', ('?') x @{ $requires  }) . ')';
    my $con_ph = 'sqitch_array('. join(', ', ('?') x @{ $conflicts }) . ')';
    my $ts     = $self->_ts_default;

    $dbh->do(qq{
        INSERT INTO events (
              event
            , change_id
            , change
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
        VALUES (?, ?, ?, ?, ?, $tag_ph, $req_ph, $con_ph, ?, ?, ?, ?, ?, $ts)
    }, undef,
        $event,
        $change->id,
        $change->name,
        $change->project,
        $change->note,
        @{ $tags      },
        @{ $requires  },
        @{ $conflicts },
        $sqitch->user_name,
        $sqitch->user_email,
        $self->_char2ts( $change->timestamp ),
        $change->planner_name,
        $change->planner_email,
    );

    return $self;
}

sub changes_requiring_change {
    my ( $self, $change ) = @_;
    # Why CTE: https://forums.cubrid.com/forums/thread.jspa?threadID=1005221
    return @{ $self->dbh->selectall_arrayref(q{
        WITH tag AS (
            SELECT tag, committed_at, project,
                   ROW_NUMBER() OVER (partition by project ORDER BY committed_at) AS rnk
              FROM tags
        )
        SELECT c.change_id, c.project, c.change, t.tag AS asof_tag
          FROM dependencies d
          JOIN changes  c ON c.change_id = d.change_id
          LEFT JOIN tag t ON t.project   = c.project AND t.committed_at >= c.committed_at
         WHERE d.dependency_id = ?
           AND (t.rnk IS NULL OR t.rnk = 1)
    }, { Slice => {} }, $change->id) };
}

sub name_for_change_id {
    my ( $self, $change_id ) = @_;
    # Why CTE: https://forums.cubrid.com/forums/thread.jspa?threadID=1005221
    return $self->dbh->selectcol_arrayref(q{
        WITH tag AS (
            SELECT tag, committed_at, project,
                   ROW_NUMBER() OVER (partition by project ORDER BY committed_at) AS rnk
              FROM tags
        )
        SELECT change || COALESCE(t.tag, '')
          FROM changes c
          LEFT JOIN tag t ON c.project = t.project AND t.committed_at >= c.committed_at
         WHERE change_id = ?
           AND (t.rnk IS NULL OR t.rnk = 1)
    }, undef, $change_id)->[0];
}

sub change_offset_from_id {
    my ( $self, $change_id, $offset ) = @_;

    # Just return the object if there is no offset.
    return $self->load_change($change_id) unless $offset;

    # Are we offset forwards or backwards?
    my ( $dir, $op ) = $offset > 0 ? ( 'ASC', '>' ) : ( 'DESC' , '<' );
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';

    my $change = $self->dbh->selectrow_hashref(qq{
        SELECT id, name, project, note, timestamp, planner_name, planner_email, tags
          FROM (
              SELECT id, name, project, note, timestamp, planner_name, planner_email, tags, rownum AS rnum
                FROM (
                  SELECT c.change_id AS id, c.change AS name, c.project, c.note,
                         $tscol AS timestamp, c.planner_name, c.planner_email,
                         $tagcol AS tags
                    FROM changes   c
                    LEFT JOIN tags t ON c.change_id = t.change_id
                   WHERE c.project = ?
                     AND c.committed_at $op (
                         SELECT committed_at FROM changes WHERE change_id = ?
                   )
                   GROUP BY c.change_id, c.change, c.project, c.note, c.planned_at,
                         c.planner_name, c.planner_email, c.committed_at
                   ORDER BY c.committed_at $dir
              )
         ) WHERE rnum = ?
    }, undef, $self->plan->project, $change_id, abs $offset) || return undef;
    $change->{timestamp} = _dt $change->{timestamp};
    return $change;
}

sub is_deployed_tag {
    my ( $self, $tag ) = @_;
    return $self->dbh->selectcol_arrayref(
        'SELECT 1 FROM tags WHERE tag_id = ?',
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
    my $file = file(__FILE__)->dir->file('cubrid.sql');
    $self->_run( '--input-file' => $file, $self->sqitch_db );

    return $self;               # ???
}

# Override for special handling of regular the expression operator and
# LIMIT/OFFSET.
sub search_events {
    my ( $self, %p ) = @_;

    # Determine order direction.
    my $dir = 'DESC';
    if (my $d = delete $p{direction}) {
        $dir = $d =~ /^ASC/i  ? 'ASC'
             : $d =~ /^DESC/i ? 'DESC'
             : hurl 'Search direction must be either "ASC" or "DESC"';
    }

    # Limit with regular expressions?
    my (@wheres, @params);
    for my $spec (
        [ committer => 'committer_name' ],
        [ planner   => 'planner_name'   ],
        [ change    => 'change'         ],
        [ project   => 'project'        ],
    ) {
        my $regex = delete $p{ $spec->[0] } // next;
        push @wheres => "REGEXP_LIKE($spec->[1], ?)";
        push @params => $regex;
    }

    # Match events?
    if (my $e = delete $p{event} ) {
        my ($in, @vals) = $self->_in_expr( $e );
        push @wheres => "event $in";
        push @params => @vals;
    }

    # Assemble the where clause.
    my $where = @wheres
        ? "\n         WHERE " . join( "\n               ", @wheres )
        : '';

    # Handle remaining parameters.
    my ($lim, $off) = (delete $p{limit}, delete $p{offset});

    hurl 'Invalid parameters passed to search_events(): '
        . join ', ', sort keys %p if %p;

    # Prepare, execute, and return.
    my $cdtcol = sprintf $self->_ts2char_format, 'committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'planned_at';
    my $sql = qq{
        SELECT event
             , project
             , change_id
             , change
             , note
             , requires
             , conflicts
             , tags
             , committer_name
             , committer_email
             , $cdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM events$where
         ORDER BY events.committed_at $dir
    };

    if ($lim || $off) {
        my @limits;
        if ($lim) {
            $off //= 0;
            push @params => $lim + $off;
            push @limits => 'rnum <= ?';
        }
        if ($off) {
            push @params => $off;
            push @limits => 'rnum > ?';
        }

        $sql = "SELECT * FROM ( SELECT ROWNUM AS rnum, i.* FROM ($sql) i ) WHERE "
            . join ' AND ', @limits;
    }

    my $sth = $self->dbh->prepare($sql);
    $sth->execute(@params);
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        delete $row->{rnum};
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

# Override to lock the changes table. This ensures that only one instance of
# Sqitch runs at one time.
sub begin_work {
    my $self = shift;
    my $dbh = $self->dbh;

    # Start transaction and lock changes to allow only one change at a time.
    $dbh->begin_work;
    $dbh->do('LOCK TABLE changes IN EXCLUSIVE MODE');
    return $self;
}

sub run_file {
    my ($self, $file) = @_;
    $self->_run('--input-file' => $file);
}

sub run_verify {
    my $self = shift;
    (my $file = shift) =~ s/"/""/g;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    $self->$meth(qq{\@"$file"});
}

sub run_handle {
    my ($self, $fh) = @_;
    my $target = $self->_script;
    open my $tfh, '<:utf8_strict', \$target;
    $self->sqitch->spool( [$tfh, $fh], $self->csql );
}

# Override to take advantage of the RETURNING expression, and to save tags as
# an array rather than a space-delimited string.
sub log_revert_change {
    my ($self, $change) = @_;
    my $dbh = $self->dbh;
    my $cid = $change->id;

    # Delete tags.
    my $sth = $dbh->prepare(
        'DELETE FROM tags WHERE change_id = ? RETURNING tag INTO ?',
    );
    $sth->bind_param(1, $cid);
    $sth->bind_param_inout_array(2, my $del_tags = [], 0, {
        ora_type => DBD::Cubrid::ORA_VARCHAR2()
    });
    $sth->execute;

    # Retrieve dependencies.
    my ($req, $conf) = $dbh->selectrow_array(q{
        SELECT (
            SELECT COLLECT(dependency)
              FROM dependencies
             WHERE change_id = ?
               AND type = 'require'
        ),
        (
            SELECT COLLECT(dependency)
              FROM dependencies
             WHERE change_id = ?
               AND type = 'conflict'
        ) FROM dual
    }, undef, $cid, $cid);

    # Delete the change record.
    $dbh->do(
        'DELETE FROM changes where change_id = ?',
        undef, $change->id,
    );

    # Log it.
    return $self->_log_event( revert => $change, $del_tags, $req, $conf );
}

sub _ts2char($) {
    my $col = shift;
    return qq{to_char($col AT TIME ZONE 'UTC', 'YYYY:MM:DD:HH24:MI:SS')};
}

sub _no_table_error  {
    return defined $DBI::err && $DBI::err == 942; # ORA-00942: table or view does not exist
}

sub _script {
    my $self   = shift;
    my $target = $self->user // '';
    if (my $pass = $self->password) {
        $pass =~ s/"/""/g;
        $target .= qq{/"$pass"};
    }
    if (my $db = $self->db_name) {
        $target .= '@';
        $db =~ s/"/""/g;
        if ($self->host || $self->port) {
            $target .= '//' . ($self->host || '');
            if (my $port = $self->port) {
                $target .= ":$port";
            }
            $target .= qq{/"$db"};
        } else {
            $target .= qq{"$db"};
        }
    }
    my %vars = $self->variables;

    return join "\n" => (
        'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
        'WHENEVER OSERROR EXIT 9;',
        'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
        (map {; (my $v = $vars{$_}) =~ s/"/""/g; qq{DEFINE $_="$v"} } sort keys %vars),
        "connect $target",
        @_
    );
}

sub _run {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->run( $self->csql, @_ );
    #local $ENV{PGPASSWORD} = $pass;
    return $sqitch->run( $self->csql, @_ );
}

sub _capture {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->capture( $self->csql, @_ );
    #local $ENV{PGPASSWORD} = $pass;
    return $sqitch->capture( $self->csql, @_ );
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
