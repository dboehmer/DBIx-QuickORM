use Test2::V0;
use lib 't/lib';
use DBIx::QuickORM::Tester qw/dbs_do all_dbs/;
use DBIx::QuickORM::Builder;

# Mimick BEGIN::Lift not being installed (it is also fine if it is really not installed)
BEGIN { $INC{'BEGIN/Lift.pm'} = 0 }

{
    $INC{'My/Table/AAA.pm'} = __FILE__;

    package My::Table::AAA;
    use DBIx::QuickORM::Builder ':TABLE_CLASS';
    use Test2::V0;

    BEGIN {
        is(\&index, exact_ref(DBIx::QuickORM::Builder->can('index')), "Have DBIx::QuickORM::index() for this scope");
    }

    BEGIN {
        meta_table aaa => sub {
            column aaa_id => sub {
                primary_key;
                serial;
                sql_spec(
                    mysql      => {type => 'INTEGER'},
                    postgresql => {type => 'SERIAL'},
                    sqlite     => {type => 'INTEGER'},

                    type => 'INTEGER',    # Fallback
                );
            };

            column foo => sub {
                sql_spec {type => 'INTEGER'};
            };
        };
    }

    BEGIN {
        not_imported_ok('index');
    }

    sub id { shift->column('aaa_id') }

    sub index { "XXXX" }

    ok(!warns { *rtable = sub { 1 } }, "No warnings for redefining exports that were purged");
}

{
    $INC{'My/Table/BBB.pm'} = __FILE__;

    package My::Table::BBB;
    use DBIx::QuickORM::Builder ':TABLE_CLASS';
    use Test2::V0;

    my $err = dies {
        meta_table bbb => sub {
            column bbb_id => sub {
                primary_key;
                serial;
                sql_spec(
                    mysql      => {type => 'INTEGER'},
                    postgresql => {type => 'SERIAL'},
                    sqlite     => {type => 'INTEGER'},

                    type => 'INTEGER',    # Fallback
                );
            };

            column foo => sub {
                sql_spec {type => 'INTEGER'};
            };
        };
    };

    like(
        $err,
        qr/meta_table must be called directly from a BEGIN block \(Or you can install 'BEGIN::Lift' to automatically wrap it in a BEGIN block\)/,
        "meta_table must be used in a BEGIN",
    );
}

dbs_do db => sub {
    my ($dbname, $dbc, $st) = @_;

    my $orm = orm sub {
        db sub {
            db_class $dbname;
            db_name 'quickdb';
            db_connect sub { $dbc->connect };
        };

        schema sub { table 'My::Table::AAA' };
    };

    ok(lives { $orm->generate_and_load_schema() }, "Generate and load schema");

    is([$orm->connection->tables], ['aaa'], "Table aaa was added");

    my $table = $orm->schema->table('aaa');
    like($table, My::Table::AAA->orm_table, "Got table data");
    is($table->row_class, 'My::Table::AAA', "row class is set");

    my $row = $orm->source('aaa')->insert(foo => 1);

    is($row->index, 'XXXX', "Can still use our definition of index()");

    is($row->id, $row->column('aaa_id'), "Added our own method to the row class");
    is($row->id, 1, "Got correct value");

    isa_ok($row, ['DBIx::QuickORM::Row', 'My::Table::AAA'], "Got properly classed row");
};


done_testing;
