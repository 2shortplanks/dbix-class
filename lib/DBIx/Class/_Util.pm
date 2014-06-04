package # hide from PAUSE
  DBIx::Class::_Util;

use warnings;
use strict;

use constant SPURIOUS_VERSION_CHECK_WARNINGS => ($] < 5.010 ? 1 : 0);

BEGIN {
  package # hide from pause
    DBIx::Class::_ENV_;

  use Config;

  use constant {

    # but of course
    BROKEN_FORK => ($^O eq 'MSWin32') ? 1 : 0,

    HAS_ITHREADS => $Config{useithreads} ? 1 : 0,

    # ::Runmode would only be loaded by DBICTest, which in turn implies t/
    DBICTEST => eval { DBICTest::RunMode->is_author } ? 1 : 0,

    # During 5.13 dev cycle HELEMs started to leak on copy
    PEEPEENESS =>
      # request for all tests would force "non-leaky" illusion and vice-versa
      defined $ENV{DBICTEST_ALL_LEAKS}                                              ? !$ENV{DBICTEST_ALL_LEAKS}
      # otherwise confess that this perl is busted ONLY on smokers
    : eval { DBICTest::RunMode->is_smoker } && ($] >= 5.013005 and $] <= 5.013006)  ? 1
      # otherwise we are good
                                                                                    : 0
    ,

    ASSERT_NO_INTERNAL_WANTARRAY => $ENV{DBIC_ASSERT_NO_INTERNAL_WANTARRAY} ? 1 : 0,

    IV_SIZE => $Config{ivsize},

    OS_NAME => $^O,
  };

  if ($] < 5.009_005) {
    require MRO::Compat;
    constant->import( OLD_MRO => 1 );
  }
  else {
    require mro;
    constant->import( OLD_MRO => 0 );
  }
}

# FIXME - this is not supposed to be here
# Carp::Skip to the rescue soon
use DBIx::Class::Carp '^DBIx::Class|^DBICTest';

use Carp 'croak';
use Scalar::Util qw(weaken blessed reftype);
use List::Util qw(first);
use overload ();

use base 'Exporter';
our @EXPORT_OK = qw(
  sigwarn_silencer modver_gt_or_eq fail_on_internal_wantarray
  refcount hrefaddr is_exception
  is_plain_value is_literal_value
);

sub sigwarn_silencer ($) {
  my $pattern = shift;

  croak "Expecting a regexp" if ref $pattern ne 'Regexp';

  my $orig_sig_warn = $SIG{__WARN__} || sub { CORE::warn(@_) };

  return sub { &$orig_sig_warn unless $_[0] =~ $pattern };
}

sub hrefaddr ($) { sprintf '0x%x', &Scalar::Util::refaddr }

sub refcount ($) {
  croak "Expecting a reference" if ! length ref $_[0];

  require B;
  # No tempvars - must operate on $_[0], otherwise the pad
  # will count as an extra ref
  B::svref_2object($_[0])->REFCNT;
}

sub is_exception ($) {
  my $e = $_[0];

  # this is not strictly correct - an eval setting $@ to undef
  # is *not* the same as an eval setting $@ to ''
  # but for the sake of simplicity assume the following for
  # the time being
  return 0 unless defined $e;

  my ($not_blank, $suberror);
  {
    local $@;
    eval {
      $not_blank = ($e ne '') ? 1 : 0;
      1;
    } or $suberror = $@;
  }

  if (defined $suberror) {
    if (length (my $class = blessed($e) )) {
      carp_unique( sprintf(
        'External exception object %s=%s(%s) implements partial (broken) '
      . 'overloading preventing it from being used in simple ($x eq $y) '
      . 'comparisons. Given Perl\'s "globally cooperative" exception '
      . 'handling this type of brokenness is extremely dangerous on '
      . 'exception objects, as it may (and often does) result in silent '
      . '"exception substitution". DBIx::Class tries to work around this '
      . 'as much as possible, but other parts of your software stack may '
      . 'not be even aware of this. Please submit a bugreport against the '
      . 'distribution containing %s and in the meantime apply a fix similar '
      . 'to the one shown at %s, in order to ensure your exception handling '
      . 'is saner application-wide. What follows is the actual error text '
      . "as generated by Perl itself:\n\n%s\n ",
        $class,
        reftype $e,
        hrefaddr $e,
        $class,
        'http://v.gd/DBIC_overload_tempfix/',
        $suberror,
      ));

      # workaround, keeps spice flowing
      $not_blank = ("$e" ne '') ? 1 : 0;
    }
    else {
      # not blessed yet failed the 'ne'... this makes 0 sense...
      # just throw further
      die $suberror
    }
  }

  return $not_blank;
}

sub modver_gt_or_eq ($$) {
  my ($mod, $ver) = @_;

  croak "Nonsensical module name supplied"
    if ! defined $mod or ! length $mod;

  croak "Nonsensical minimum version supplied"
    if ! defined $ver or $ver =~ /[^0-9\.\_]/;

  local $SIG{__WARN__} = sigwarn_silencer( qr/\Qisn't numeric in subroutine entry/ )
    if SPURIOUS_VERSION_CHECK_WARNINGS;

  croak "$mod does not seem to provide a version (perhaps it never loaded)"
    unless $mod->VERSION;

  local $@;
  eval { $mod->VERSION($ver) } ? 1 : 0;
}

sub is_literal_value ($) {
  (
    ref $_[0] eq 'SCALAR'
      or
    ( ref $_[0] eq 'REF' and ref ${$_[0]} eq 'ARRAY' )
  ) ? 1 : 0;
}

# FIXME XSify - this can be done so much more efficiently
sub is_plain_value ($) {
  no strict 'refs';
  (
    # plain scalar
    (! length ref $_[0])
      or
    (
      blessed $_[0]
        and
      # deliberately not using Devel::OverloadInfo - the checks we are
      # intersted in are much more limited than the fullblown thing, and
      # this is a relatively hot piece of code
      (
        # either has stringification which DBI prefers out of the box
        #first { *{$_ . '::(""'}{CODE} } @{ mro::get_linear_isa( ref $_[0] ) }
        overload::Method($_[0], '""')
          or
        # has nummification and fallback is *not* disabled
        (
          $_[1] = first { *{"${_}::(0+"}{CODE} } @{ mro::get_linear_isa( ref $_[0] ) }
            and
          ( ! defined ${"$_[1]::()"} or ${"$_[1]::()"} )
        )
      )
    )
  ) ? 1 : 0;
}

{
  my $list_ctx_ok_stack_marker;

  sub fail_on_internal_wantarray {
    return if $list_ctx_ok_stack_marker;

    if (! defined wantarray) {
      croak('fail_on_internal_wantarray() needs a tempvar to save the stack marker guard');
    }

    my $cf = 1;
    while ( ( (caller($cf+1))[3] || '' ) =~ / :: (?:

      # these are public API parts that alter behavior on wantarray
      search | search_related | slice | search_literal

        |

      # these are explicitly prefixed, since we only recognize them as valid
      # escapes when they come from the guts of CDBICompat
      CDBICompat .*? :: (?: search_where | retrieve_from_sql | retrieve_all )

    ) $/x ) {
      $cf++;
    }

    if (
      (caller($cf))[0] =~ /^(?:DBIx::Class|DBICx::)/
    ) {
      my $obj = shift;

      DBIx::Class::Exception->throw( sprintf (
        "Improper use of %s(%s) instance in list context at %s line %d\n\n\tStacktrace starts",
        ref($obj), hrefaddr($obj), (caller($cf))[1,2]
      ), 'with_stacktrace');
    }

    my $mark = [];
    weaken ( $list_ctx_ok_stack_marker = $mark );
    $mark;
  }
}

1;
