package DBIx::QuickORM::Source;
use strict;
use warnings;

use Carp qw/croak/;
use List::Util qw/zip min/;
use Scalar::Util qw/blessed weaken/;
use DBIx::QuickORM::Util qw/parse_hash_arg/;

use DBIx::QuickORM::Row;
use DBIx::QuickORM::Select;
use DBIx::QuickORM::Select::Async;

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <schema
    <table
    <orm
    <ignore_cache
};

use DBIx::QuickORM::Util::Has qw/Created Plugins/;

sub init {
    my $self = shift;

    my $table = $self->{+TABLE} or croak "The 'table' attribute must be provided";
    croak "The 'table' attribute must be an instance of 'DBIx::QuickORM::Table'" unless $table->isa('DBIx::QuickORM::Table');

    my $schema = $self->{+SCHEMA} or croak "The 'schema' attribute must be provided";
    croak "The 'schema' attribute must be an instance of 'DBIx::QuickORM::Schema'" unless $schema->isa('DBIx::QuickORM::Schema');

    my $connection = $self->{+CONNECTION} or croak "The 'connection' attribute must be provided";
    croak "The 'connection' attribute must be an instance of 'DBIx::QuickORM::Connection'" unless $connection->isa('DBIx::QuickORM::Connection');

    weaken($self->{+CONNECTION});
    weaken($self->{+ORM});

    $self->{+IGNORE_CACHE} //= 0;
}

sub uncached {
    my $self = shift;
    my ($callback) = @_;

    if ($callback) {
        local $self->{+IGNORE_CACHE} = 1;
        return $callback->($self);
    }

    return $self->clone(IGNORE_CACHE => 1);
}

sub transaction {
    my $self = shift;
    $self->{+CONNECTION}->transaction(@_);
}

sub clone {
    my $self   = shift;
    my %params = @_;
    my $class  = blessed($self);

    unless ($params{+CREATED}) {
        my @caller = caller();
        $params{+CREATED} = "$caller[1] line $caller[2]";
    }

    return $class->new(
        %$self,
        %params,
    );
}

sub update_or_insert {
    my $self = shift;
    my $row_data = $self->parse_hash_arg(@_);

    unless ($self->{+IGNORE_CACHE}) {
        if (my $cached = $self->{+CONNECTION}->from_cache($self, $row_data)) {
            $cached->update($row_data);
            return $cached;
        }
    }

    my $row = $self->transaction(sub {
        if (my $row = $self->find($row_data)) {
            $row->update($row_data);
            return $row;
        }

        return $self->insert($row_data);
    });

    $row->set_txn_id($self->{+CONNECTION}->txn_id);

    return $self->{+CONNECTION}->cache_source_row($self, $row) unless $self->{+IGNORE_CACHE};
    return $row;
}

sub find_or_insert {
    my $self = shift;
    my $row_data = $self->parse_hash_arg(@_);

    unless ($self->{+IGNORE_CACHE}) {
        if (my $cached = $self->{+CONNECTION}->from_cache($self, $row_data)) {
            $cached->update($row_data);
            return $cached;
        }
    }

    my $row = $self->transaction(sub { $self->find($row_data) // $self->insert($row_data) });

    $row->set_txn_id($self->{+CONNECTION}->txn_id);

    return $self->{+CONNECTION}->cache_source_row($self, $row) unless $self->{+IGNORE_CACHE};
    return $row;
}

sub _parse_find_and_fetch_args {
    my $self = shift;

    return {@_} unless @_ == 1;
    if (ref($_[0]) eq 'HASH') {
        return $_[0] if $_[0]->{where};
        return { where => $_[0] };
    }

    my $pk = $self->{+TABLE}->primary_key;
    croak "Cannot pass in a single value for find() or fetch() when table has no primary key"         unless $pk && @$pk;
    croak "Cannot pass in a single value for find() or fetch() when table has a compound primary key" unless @$pk == 1;
    return {where => {$pk->[0] => $_[0]}};
}

sub select_async {
    my $self = shift;
    my %params = @_;

    croak "Cannot use async select inside a transaction (use `ignore_transaction => 1` to do it anyway, knowing that the async select will not see any uncommited changes)"
        if $self->{+CONNECTION}->in_transaction && !$params{ignore_transaction};

    my $params;
    if (ref($_[0]) eq 'HASH') {
        $params = $self->_parse_find_and_fetch_args(shift(@_));
        $params->{order_by} = shift(@_) if @_ == 1;
    }

    $params = {%{$params // {}}, @_} if @_;

    return DBIx::QuickORM::Select::Async->new(source => $self, %$params);
}

sub select {
    my $self = shift;

    # {where}
    # {where}, order
    # where => ..., order => ..., ...
    # {where => { ... }, order => ..., ...}
    my $params;
    if (ref($_[0]) eq 'HASH') {
        $params = $self->_parse_find_and_fetch_args(shift(@_));
        $params->{order_by} = shift(@_) if @_ == 1;
    }

    $params = {%{$params // {}}, @_} if @_;

    return DBIx::QuickORM::Select->new(source => $self, %$params);
}

sub count_select {
    my $self = shift;
    my ($params) = @_;

    my $where = $params->{where};

    my $table = $self->{+TABLE};
    my $con = $self->{+CONNECTION};

    my ($stmt, @bind) = $con->sqla->select($table->sqla_source, ['count(*)'], $where);

    my $sth = $con->dbh->prepare($stmt);
    $sth->execute(@bind);

    my ($count) = $sth->fetchrow_array;

    $count //= 0;

    if (my $limit = $params->{limit}) {
        $count = min($count, $limit);
    }

    return $count;
}

sub do_select {
    my $self = shift;
    my ($params) = @_;

    my $where = $params->{where};
    my $order = $params->{order_by};

    my $con = $self->{+CONNECTION};

    my ($source, $cols, $relmap) = $self->_source_and_cols($params->{prefetch});
    my ($stmt, @bind) = $con->sqla->select($source, $cols, $where, $order ? $order : ());

    if (my $limit = $params->{limit}) {
        $stmt .= " LIMIT ?";
        push @bind => $limit;
    }

    my $sth = $con->dbh->prepare($stmt);
    $sth->execute(@bind);

    my @out;
    while (my $data = $sth->fetchrow_arrayref) {
        my $row = {};
        @{$row}{@$cols} = @$data;
        $self->expand_relations($row, $relmap) if $relmap;
        push @out => $self->_expand_row($row);
    }

    return \@out;
}

sub find {
    my $self  = shift;
    my $params = $self->_parse_find_and_fetch_args(@_);
    my $where = $params->{where};

    my $con = $self->{+CONNECTION};

    # See if there is a cached copy with the data we have
    unless ($self->{+IGNORE_CACHE}) {
        my $cached = $con->from_cache($self, $where);
        return $cached if $cached;
    }

    my $data = $self->fetch($params) or return;

    return $self->_expand_row($data);
}

# Get hashref data for one object (no cache)
sub fetch {
    my $self  = shift;
    my $params = $self->_parse_find_and_fetch_args(@_);
    my $where = $params->{where};

    my $con = $self->{+CONNECTION};

    my ($source, $cols, $relmap) = $self->_source_and_cols($params->{prefetch});
    my ($stmt, @bind) = $con->sqla->select($source, $cols, $where);
    my $sth = $con->dbh->prepare($stmt);
    $sth->execute(@bind);

    my $data  = $sth->fetchrow_arrayref or return;
    my $extra = $sth->fetchrow_arrayref;
    croak "Multiple rows returned for fetch/find operation" if $extra;

    my $row = {};
    @{$row}{@$cols} = @$data;

    $self->expand_relations($row, $relmap) if $relmap;

    return $row;
}

sub insert_row {
    my $self = shift;
    my ($row) = @_;

    croak "Row already exists in the database" if $row->from_db;

    my $row_data = $row->dirty;

    my $data = $self->_insert($row_data);

    $row->refresh($data);

    my $con = $self->{+CONNECTION};

    return $row if $self->{+IGNORE_CACHE};
    return $con->cache_source_row($self, $row);
}

sub insert {
    my $self     = shift;
    my $row_data = $self->parse_hash_arg(@_);

    my $data = $self->_insert($row_data);
    my $row  = DBIx::QuickORM::Row->new(from_db => $data, source => $self);

    my $con = $self->{+CONNECTION};
    return $row if $self->{+IGNORE_CACHE};
    return $con->cache_source_row($self, $row);
}

sub _insert {
    my $self = shift;
    my ($row_data) = @_;

    my $con   = $self->{+CONNECTION};
    my $ret   = $con->db->insert_returning_supported;
    my $table = $self->{+TABLE};
    my $tname = $table->name;

    my ($stmt, @bind) = $con->sqla->insert($tname, $row_data, $ret ? {returning => [$table->column_names]} : ());

    my $dbh = $con->dbh;
    my $sth = $dbh->prepare($stmt);
    $sth->execute(@bind);

    my $data;
    if ($ret) {
        $data = $sth->fetchrow_hashref;
    }
    else {
        my $pk_fields = $self->{+TABLE}->primary_key;

        my $where;
        if (@$pk_fields > 1) {
            $where = {map { my $v = $row_data->{$_} or croak "Auto-generated compound primary keys are not supported for databses that do not support 'returning' functionality"; ($_ => $v) } @$pk_fields};
        }
        else {
            my $kv = $dbh->last_insert_id(undef, undef, $tname);
            $where = {$pk_fields->[0] => $kv};
        }

        my ($stmt, @bind) = $con->sqla->select($table->sqla_source, $table->sqla_columns, $where);
        my $sth = $dbh->prepare($stmt);
        $sth->execute(@bind);
        $data = $sth->fetchrow_hashref;
    }

    return $data;
}

sub vivify {
    my $self = shift;
    my $row_data = $self->parse_hash_arg(@_);
    return DBIx::QuickORM::Row->new(dirty => $row_data, source => $self);
}

sub DESTROY {
    my $self = shift;

    my $con = $self->{+CONNECTION} or return;
    $con->remove_source_cache($self);

    return;
}

sub _expand_row {
    my $self = shift;
    my ($data) = @_;

    my %relations;

    for my $key (keys %$data) {
        my $rel = $data->{$key} or next;
        next unless ref($rel) eq 'HASH';

        my $accessor = $key;
        my $relation = $self->{+TABLE}->relation($accessor);
        my $specs = $relation->get_accessor($self->{+TABLE}->name, $accessor);
        my $source = $self->{+ORM}->source($specs->{foreign_table});

        $relations{$key} = $source->_expand_row(delete $data->{$key});
    }

    return DBIx::QuickORM::Row->new(from_db => $data, source => $self, cached_relations => \%relations)
        if $self->{+IGNORE_CACHE};

    my $con = $self->{+CONNECTION};

    if (my $cached = $con->from_cache($self, $data)) {
        $cached->refresh($data);
        $cached->update_cached_relations(\%relations);
        return $cached;
    }

    return $con->cache_source_row(
        $self,
        DBIx::QuickORM::Row->new(from_db => $data, source => $self, cached_relations => \%relations),
    );
}

sub _source_and_cols {
    my $self = shift;
    my ($prefetch) = @_;

    my $table = $self->{+TABLE};
    my $precache_sets = $table->precache_relations($prefetch);

    return ($table->sqla_source, $table->sqla_columns) unless @$precache_sets;

    # This causes an sqla autoload error, so for now use an empty string
    my $qc = ''; #$self->{+CONNECTION}->sqla->quote_char() // '';

    my $tname = $table->sqla_source;
    my $source = "${qc}${tname}${qc}";
    my @cols = @{$table->sqla_columns};

    my %relmap;
    my %ases;
    my @todo = @$precache_sets;

    while (my $path = shift @todo) {
        my $pc = pop @$path;

        my $ftable = $pc->{foreign_table};
        $ases{$ftable} //= 1;
        my $as = $ftable . $ases{$ftable}++;

        $relmap{$as} = $path;

        my $ts = $self->orm->source($ftable);
        my $t2 = $ts->table;

        my $s2 = $t2->sqla_source;
        my $c2 = $t2->sqla_columns;

        $source .= " JOIN ${qc}${s2}${qc} AS $as";

        my $lc = join ", ", @{$pc->{local_columns}};
        my $fc = join ", ", @{$pc->{foreign_columns}};
        if ($lc eq $fc) {
            $source .= " USING($lc)";
        }
        else {
            $source .= " ON(" . (map { "$_->[0] = $_->[1]" } zip($pc->{local_columns}, $pc->{foreign_columns})) . ")";
        }

        push @cols => map { qq[${as}.$_] } @$c2;

        push @todo => map { unshift @{$_} => @$path; $_} @{$t2->precache_relations};
    }

    return (\$source, \@cols, \%relmap);
}

sub expand_relations {
    my $self = shift;
    my ($data, $relmap) = @_;

    return $data unless $relmap && keys %$relmap;

    for my $key (keys %$data) {
        next unless $key =~ m/^(.+)\.(.+)$/;
        my ($rel, $col) = ($1, $2);
        my $path = $relmap->{$rel} or next;

        my $p = $data;
        for my $pt (@$path) {
            $p = $p->{$pt} //= {};
        }

        $p->{$col} = delete $data->{$key};
    }

    return $data;
}

1;
