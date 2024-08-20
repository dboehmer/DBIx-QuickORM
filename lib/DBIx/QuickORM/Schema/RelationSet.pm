package DBIx::QuickORM::Schema::RelationSet;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

sub new;

use DBIx::QuickORM::Util::HashBase qw{
    +by_index
    +by_table_and_name
};

sub new {
    my $class = shift;
    my (@rels) = @_;

    my $self = bless({by_index => {}, by_table_and_name => {}}, $class);

    $self->add_relation($_) for @rels;

    return $self;
}

sub add_relation {
    my $self = shift;
    my ($rel) = @_;

    my $index = $rel->index;
    return if $self->{+BY_INDEX}->{$index}; # Duplicate
    $self->{+BY_INDEX}->{$index} = $rel;

    for my $m (@{$rel->members}) {
        my $table = $m->table;
        my $name  = $m->name;

        if (my $have = $self->{+BY_TABLE_AND_NAME}->{$table}->{$name}) {
            croak "Two relations have the same table-name combination ($table -> $name):\n"
                . "  relation 1 '" . $rel->name  . "' " . ($rel->created // "")  . "\n"
                . "  relation 2 '" . $have->name . "' " . ($have->created // "") . "\n";
        }

        $self->{+BY_TABLE_AND_NAME}->{$table}->{$name} = $rel;
    }

    return $rel;
}

sub by_index {
    my $self = shift;
    my ($index) = @_;
    return $self->{+BY_INDEX}->{$index} // undef;
}

sub equivelent {
    my $self = shift;
    my ($rel) = @_;
    return $self->{+BY_INDEX}->{$rel->index} // undef;
}

sub by_table_and_name {
    my $self = shift;
    my ($table_name, $name) = @_;
    my $table = $self->{+BY_TABLE_AND_NAME}->{$table_name} or return undef;
    return $table->{$name} // undef;
}

sub merge {
    my $self = shift;
    my ($them) = @_;

    return blessed($self)->new(
        $self->all,
        $them->all,
    );
}

sub merge_in {
    my $self = shift;
    my ($them) = @_;
    $self->add_relation($_) for $them->all;
}

sub all {
    my $self = shift;
    return values %{$self->{+BY_INDEX}};
}

sub names_for_table {
    my $self = shift;
    my ($table) = @_;
    return keys %{$self->{+BY_TABLE_AND_NAME}->{$table} // {}};
}

sub clone {
    my $self = shift;
    return blessed($self)->new($self->all);
}

1;
