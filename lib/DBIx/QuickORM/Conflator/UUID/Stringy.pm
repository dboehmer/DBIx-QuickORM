package DBIx::QuickORM::Conflator::UUID::Stringy;
use strict;
use warnings;

our $VERSION = '0.000003';

use parent 'DBIx::QuickORM::Conflator::UUID';
use DBIx::QuickORM::Util::HashBase;

sub _qorm_sql_type { 'VARCHAR(36)' }

1;
