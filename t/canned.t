#!/usr/bin/env perl

use Test::More;
unless ( eval { require DBD::SQLite } ) {
  Test::More->import( skip_all => 'No SQLite driver' );
  exit 0;
}

### Test RDB class using in-core scratch db
package My::Test::RDB;

use 5.010;
use parent 'Rose::DB';

__PACKAGE__->use_private_registry;

__PACKAGE__->register_db( domain   => 'test',
                          type     => 'vapor',
                          driver   => 'SQLite',
                          database => ':memory:',
                        );

# SQLite in-memory db evaporates when original dbh is closed.
sub dbi_connect {
  my( $self, @args ) = @_;
  state $dbh = $self->SUPER::dbi_connect(@args);
  $dbh;
}

### Test class supplying broken BUILDARGS
package My::Test::CannedQuery;
use parent 'Rose::DBx::CannedQuery';

sub BUILDARGS { shift; return ref $_[0] ? $_[0] : +{@_} }

### And finally, the rest of the tests
package main;

require Rose::DBx::CannedQuery::SimpleQueryCache; # Tested in 001-cache.t

# Set up the test environment
my $rdb = new_ok( 'My::Test::RDB' => [ connect_options => { RaiseError => 1 },
                                       domain          => 'test',
                                       type            => 'vapor'
                                     ],
                  'Setup test db'
                );
my $dbh = $rdb->dbh;
$dbh->do(
  'CREATE TABLE test ( id INTEGER PRIMARY KEY,
                              name VARCHAR(16),
                              color VARCHAR(8) );'
        );
foreach my $data ( [ 1, q{'widget'}, q{'blue'} ],
                   [ 2, q{'fidget'}, q{'red'} ],
                   [ 3, q{'midget'}, q{'green'} ],
                   [ 4, q{'gidget'}, q{'red'} ]
  ) {
  $dbh->do( q[INSERT INTO test VALUES ( ] . join( ',', @$data ) . ' );' );
}

# . . . and start the testing
my $by_name = new_ok( 'Rose::DBx::CannedQuery' => [
                                     rdb_class      => 'My::Test::RDB',
                                     rdb_params    => { domain => 'test',
                                                         type   => 'vapor'
                                                       },
                                     sql => 'SELECT * FROM test WHERE color = ?'
                      ],
                      'Create by name'
                    );
is( $by_name->rdb_class, 'My::Test::RDB', 'RDB class name' );
is_deeply( $by_name->rdb_params,
           { domain => 'test', type => 'vapor' },
           'RDB datasource attributes' );
is( $by_name->sql, 'SELECT * FROM test WHERE color = ?', 'Query SQL' );

{
  my $sth = eval { $by_name->execute('blue'); };
  ok( $sth, 'execute()' );
  is( $sth, $by_name->sth, 'Statement handle' );
  is_deeply( $sth->fetchall_arrayref,
             [ [ 1, 'widget', 'blue' ] ],
             'Result via sth' );
}

is_deeply([ $by_name->results('red') ],
	  [
	    { id => 2, name => 'fidget', color => 'red' },
	    { id => 4, name => 'gidget', color => 'red' },
	  ],
	 'results() - list');
is($by_name->results('red'), 2, 'results() - scalar');

is_deeply($by_name->resultref([ 'red' ]),
	  [
	    { id => 2, name => 'fidget', color => 'red' },
	    { id => 4, name => 'gidget', color => 'red' },
	  ],
	 'resultref() - hashref');

is_deeply($by_name->resultref([ 'red' ], [ [ 1 ] ]),
	  [
	    [ 'fidget' ],
	    [ 'gidget' ],
	  ],
	 'resultref() - arrayref sliced');

is_deeply($by_name->resultref([ 'red' ], [ {}, 1 ]),
	  [
	    { id => 2, name => 'fidget', color => 'red' },
	  ],
	 'resultref() - limit to 1');

is_deeply($by_name->sth->fetchall_arrayref,
	  [
	    [ 4, 'gidget', 'red' ]
	  ],
	 'resultset still live');

my $by_ref = new_ok('Rose::DBx::CannedQuery' =>
		   [ rdb => $by_name->rdb,
		     sql => q[SELECT * FROM test WHERE name LIKE '?idget']
		   ],
		   'Create by reference');
is($by_ref->rdb_class, 'My::Test::RDB','RDB class name (recovered)');
is_deeply($by_ref->rdb_params,
	  { domain => 'test', type => 'vapor' },
	 'RDB datasource attributes (recovered)');
is($by_ref->sql,q[SELECT * FROM test WHERE name LIKE '?idget'],'Query SQL');

# We do this instead of creating a new object because of the smoke and
# mirrors we're using in our test RDB class to recycle a single dbh
$by_ref->rdb->dbh->{RaiseError} = 0;
$by_ref->rdb->dbh->{PrintError} = 0;

ok( ( not eval { $by_ref->execute(qw/ crash bang /) } and
        $@ =~ /^Error executing query/
    ),
    'Execute failure trapped'
  );

my $broken_source =
  Rose::DBx::CannedQuery->new( sql            => 'SELECT * FROM test',
                               rdb_class      => 'My::Test::RDB',
                               rdb_params     => {} );

ok( ( not eval { $broken_source->rdb } and $@ =~ /^No database information/ ),
    'Bad datasource error trapped' );

my $broken_retcon = My::Test::CannedQuery->new( sql => 'SELECT * FROM test' );

ok( ( not eval { $broken_retcon->rdb_class } and
        $@ =~ /^Can't recover Rose::DB class/
    ),
    'Class retcon error trapped'
  );

ok( ( not eval { $broken_retcon->rdb_params } and
        $@ =~ /^Can't recover Rose::DB datasource/
    ),
    'Datasource retcon error trapped'
  );

my $broken_sql =
  Rose::DBx::CannedQuery->new( sql => 'SELECT * FROM not_there',
                               rdb => $by_ref->rdb );

ok( ( not eval { $broken_sql->sth } and $@ =~ /^Error preparing query/ ),
    'Bad SQL error trapped' );

my(%args) = ( rdb_class      => 'My::Test::RDB',
	      rdb_params     => { domain => 'test',
				  type   => 'vapor'
				},
	      sql => 'SELECT * FROM test WHERE color = ?' );

ok(! eval { $by_ref->_query_cache(1) } && $@ =~ /via a class method/,
   "Can't change query cache as instance method");
ok( eval { Rose::DBx::CannedQuery->_query_cache(
	     Rose::DBx::CannedQuery::SimpleQueryCache->new ) },
    'But can change it as a class method');

my $qry = 
  Rose::DBx::CannedQuery->new_or_cached(%args);
isa_ok($qry, 'Rose::DBx::CannedQuery', 'new_or_cached succeeds');
is($qry,
   Rose::DBx::CannedQuery->new_or_cached(\%args),
   'new_or_cached gets cached query');

$qry->execute('red');
my $row1 = $qry->sth->fetchrow_hashref;
my $row2 = Rose::DBx::CannedQuery->new_or_cached(%args)->sth->fetchrow_hashref;

ok($row1 && $row2 &&
   $row1->{color} eq 'red' && $row2->{color} eq 'red' &&
   $row1->{id} != $row2->{id},
   'Cached query undisturbed');

$qry->sth->finish;  # Reset active flag to avoid warning

done_testing;
