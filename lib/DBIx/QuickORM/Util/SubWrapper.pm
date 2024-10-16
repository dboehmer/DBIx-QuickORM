package DBIx::QuickORM::Util::SubWrapper;
use strict;
use warnings;

use Scalar::Util();
use Sub::Util();
use Carp();
$Carp::Internal{(__PACKAGE__)}++;

use overload(
    fallback => 1,
    '""'     => sub { "" . $_[0]->() },
    '0+'     => sub { 0 + $_[0]->() },
    'bool'   => sub { !!$_[0]->() },
);

sub new {
    my $class = shift;
    my ($wrap, %params) = @_;

    my @caller = caller;

    Carp::croak("'$wrap' is not a blessed object") unless Scalar::Util::blessed($wrap);

    my $weaken = delete $params{weaken};

    Carp::croak("Invalid params passed into new: " . join ', ' => sort keys %params)
        if keys %params;

    if ($weaken) {
        Scalar::Util::weaken($wrap);

        return bless(
            sub { $wrap // Carp::croak("Weakly wrapped object created at $caller[1] line $caller[2] has gone away") },
            $class,
        );
    }

    return bless(sub { $wrap }, $class);
}

sub import {}
sub unimport {}
sub DESTROY {}

our $AUTOLOAD;
sub AUTOLOAD {
    my ($self) = @_;

    my $meth = $AUTOLOAD;
    $meth =~ s/^.*:://g;

    my $class = Scalar::Util::blessed($self) // $self;

    Carp::croak(qq{Can't locate object method "$meth" via package "$self"})
        unless Scalar::Util::blessed($self);

    my $sub = $self->can($meth) or Carp::croak(qq{Can't locate object method "$meth" via package "$class"});

    goto &$sub;
}

sub can {
    my $self = shift;

    return $self->UNIVERSAL::can(@_) unless Scalar::Util::blessed($self);

    if (my $sub = $self->UNIVERSAL::can(@_)) {
        return $sub;
    }

    my $wrap = $self->() // return;
    return !!0 unless $wrap->can(@_);

    my ($meth) = @_;

    return Sub::Util::set_subname($meth => sub { my $self = shift; my $w = $self->(); $w->$meth(@_) });
}

sub isa {
    my $self = shift;

    return !!1 if $self->UNIVERSAL::isa(@_);
    my $wrap = $self->() // return !!0;
    return $wrap->isa(@_);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

DBIx::QuickORM::Util::SubWrapper - Wrap on object in a blessed coderef that
delegates all method calls to the wrapped object.

=head1 DESCRIPTION

Sometimes it is useful to "hide" an object, for example from Data::Dumper, but
still embed it inside structures and have it be fully functional. This tool
does that.

Simply wrap your annoying object in this sub, Data::Dumper will simply dump
C<bless( sub { "DUMMY" }, 'DBIx::QuickORM::Util::SubWrapper' );> when it is
encountered. However you can still call any method on it that is valid for the
underlying method. Even Stringificaton, numerification and boolean overloading
will be passed on!

=head1 SYNOPSIS

Honestly the unit test for this class is a perfect demonstration of how it works.

First, some boilerplate:

    use Test2::V0;
    use DBIx::QuickORM::Util::SubWrapper;
    use Data::Dumper;

Set up some fake class to work with:

    BEGIN {
        package My::Base;
        package My::Package;

        use overload(
            fallback => 1,
            '""'   => sub { "I am a teapot!" }, # String overloading means this object in a string says "I am a teapot!"
            '0+'   => sub { 10 },               # Number overloading means that in math this object is a value of 10
            'bool' => sub { !!0 },              # Boolean overloading means that this object is flse in conditionals
        );

        # Adding a base class just for testing later
        push @My::Package::ISA => 'My::Base';

        # new method, self explanatory
        sub new { my $class = shift; bless({@_}, $class) };

        # Some methods to try
        sub one { 1 }
        sub bob { "bob" }
        sub echo { [@_] }
    }

Make our original, and a wrapped copy:

    my $it = My::Package->new();
    my $wr = DBIx::QuickORM::Util::SubWrapper->new($it);

These 3 methods are identical for both the original and the copy:

    is($wr->one(1, 2, 3), $it->one(1, 2, 3), "Method 'one' retuns the same thing on both the original and wrapped");
    is($wr->bob(1, 2, 3), $it->bob(1, 2, 3), "Method 'bob' retuns the same thing on both the original and wrapped");
    is($wr->echo(1, 2, 3), $it->echo(1, 2, 3), "Method 'echo' retuns the same thing on both the original and wrapped");

isa() and can() tests, if they return something meaningful on the original,
they do for the wrapper as well.

B<NOTE:> the wrapper also returns true if you check if it is a wrapper, this is
intentional as it makes it possible to distinguish a wrapped and unwrapped
form.

    isa_ok($wr, [qw/DBIx::QuickORM::Util::SubWrapper My::Package My::Base/], "isa passes though");
    can_ok($wr, [qw/one bob echo/], "can() delegates");

Extra can() tests:

    ok(!$wr->can('fake'), "can() returns false if there is no method");
    my $bob = $wr->can('bob');
    ref_ok($bob, 'CODE', "Got a coderef");
    is($wr->bob, "bob", "coderef works on object");

Extra isa() tests:

    ok($wr->isa('My::Package'), "Direct isa() test positive");
    ok(!$wr->isa('My::Fake'), "Direct isa() test negative");

These verify that overloading passes thorugh:

    is("$wr", "I am a teapot!", "String overloading is passed on");
    is(1 + $wr, 11, "Number overloading is passed on");
    is(!!$wr, F(), "Bool overloading is passed on");

L<Data::Dumper> simply dumps the dummy sub, so if our object is 1000 lines long
when dumped, we no longer have to see it. I am looking at you L<DateTime>!

    like(
        Dumper($wr),
        qr/bless\( sub \{ "DUMMY" \}, 'DBIx::QuickORM::Util::SubWrapper' \)/,
        "Does not dump the wrapped object"
    );

The following tests verify that error messages are correct when there is no
method:

    my $line;
    like(
        dies { $line = __LINE__; DBIx::QuickORM::Util::SubWrapper->foo },
        qr/Can't locate object method "foo" via package "DBIx::QuickORM::Util::SubWrapper" at \Q${ \__FILE__ } line $line\E/,
        "Calling for a bad sub on class instead of blessed object has a sane error",
    );

    like(
        dies { $line = __LINE__; $wr->foo },
        qr/Can't locate object method "foo" via package "DBIx::QuickORM::Util::SubWrapper" at \Q${ \__FILE__ } line $line\E/,
        "Calling for a bad sub on an instance has a sane error",
    );

=head1 ADDITIONAL CONSTRUCTOR OPTIONS

=over 4

=item new($thing, weaken => 1)

This will weaken the reference to $thing, so if all other references go away
this one will too, causing this wrapper to be a wrapper around 'undef'.

If this happens there will be errors to this effect when you try to call
methods on it:

    my $it = ...;
    $wr = DBIx::QuickORM::Util::SubWrapper->new($it, weaken => 1);

    # This works (assuming $it has a bob method)
    $wr->bob;

    # Remove the last non-weak reference to $it
    $it = undef;

    # This will throw an exception:
    $wr->bob;

The exception looks like this (line numbers and filenames will change to match your actual code)

    Weakly wrapped object created at test.t line 2 has gone away at test.t line 10.

The error message will list where the wrapper was created (file + line) as well
as the file+line where it failed.

=back

=head1 EXTRA NOTES:

The following methods are all implemented as empty on the wrapper, calling them
B<WILL NOT> call them on the wrapped item:

=over 4

=item import()

=item unimport()

Because of the way these are called, and how they work, having the
import()/unimport() methods delegate is just asking for trouble.

=item DESTROY

DESTROY() is magical, and leaving it unimplemented causes AUTOLOAD() to
complain loudly. Also delegating it would lead to a double-destroy.

=back

=head1 SOURCE

The source code repository for DBIx-QuickORM can be found at
L<http://github.com/exodist/DBIx-QuickORM/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut

