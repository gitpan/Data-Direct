package Data::Direct;

$VERSION = 0.01;

require Exporter;
@EXPORT = qw(edit);
@ISA = qw(Exporter);

use DBI;

sub new {
    my ($class, $dsn, $user, $pass, $table, $filter, $add) = @_;
    my $self = {};
    bless $self, $class;
    $self->{' dsn'} = $dsn;
    my $dbh;
    eval '$dbh = DBI->connect($dsn, $user, $pass, {AutoCommit => 0});';
    $dbh = DBI->connect($dsn, $user, $pass) unless ($dbh);
    return undef unless ($dbh);
    $self->{' dbh'} = $dbh;
    my $sql = "SELECT * FROM $table" . ($filter ? " WHERE $filter" : "")
            . ($add ? " $add" : "");
    my $sth = $dbh->prepare($sql);
    return undef unless ($sth);
    $self->{' table'} = $table;
    $self->{' filter'} = $filter;
    $sth->execute();
    my $fields = $sth->{NAME};
    $self->{' fields'} = $fields;
    my $r, @rs;
    while ($r = $sth->fetchrow_arrayref) {
        push(@rs, [@$r]);
    }
    $self->{' recs'} = \@rs;
    undef $sth;
    $self->fetch(0);
    $self->{' bookmarks'} = {};
    $self->{' zap'} = [];
    $self;
}

sub bind {
    my $self = shift;
    my %hash = @_;
    $self->{' binding'} = \%hash;
    $self->fetch;
}

sub simplebind {
    my ($self, $pkg) = @_;
    my @fields = @{$self->{' fields'}};
    my @ary = map {($_, \${"${pkg}::$_"})} @fields;
    $self->bind(@ary);
}

sub flush {
    my $self = shift;
    my $param = shift;
    my ($table, $filter, $fields, $rs, $dbh) = 
        @$self{(' table', ' filter', ' fields', ' recs', ' dbh')};
    my $sql = "DELETE FROM $table" . ($filter ? " WHERE $filter" : "");
    $dbh->do($sql);
    return if ($param eq 'pseudo');
    $sql = "INSERT INTO $table (" . join(", ", @$fields) . ") VALUES ("
        . join(", ", map {"?";} @$fields) . ")";
    my $sth = $dbh->prepare($sql);
    my $i;
    foreach (@$rs) {
        $sth->execute(@$_) unless ($self->{' zap'}->[$i++]);
    }
    eval '$dbh->commit;' unless ($dbh->{AutoCommit});
    $dbh->disconnect;
}

sub recs {
    my $self = shift;
    scalar(@{$self->{' recs'}});
}

sub rows {
    my $self = shift;
    $self->recs - $self->{' dels'};
}

sub cursor {
    my $self = shift;
    $self->{' cursor'};
}

sub fetch {
    my $self = shift;
    my $rs = $self->{' recs'};
    my $rec;
    if (defined($_[0])) {
        $rec = shift;
        return undef if ($rec < 0 || $rec > @$rs);
        $self->{' cursor'} = $rec;
        return undef if ($rec == @$rs);
    } else {
        $rec = $self->{' cursor'};
    }
    my $ref = $rs->[$rec];
    my @fields = @{$self->{' fields'}};
    my $bind = $self->{' binding'};
    foreach (@$ref) {
        my $col = shift @fields;
        my $ref = $bind->{$col};
        $$ref = $_ if (ref($ref));
        $self->{$col} = $_;
    }
    1;
}

sub addnew {
    my $self = shift;
    my $rs = $self->{' recs'};
    my $fields = $self->{' fields'};
    my @ary;
    foreach (@$fields) {
        $self->{$_} = undef;
        push(@ary, undef)
    }
    push(@$rs, \@ary);
}

sub setbookmark {
    my ($self, $name) = @_;
    $self->{' bookmarks'}->{$name} = $self->cursor;
}

sub gotobookmark {
    my ($self, $name) = @_;
    $self->fetch($self->{' bookmarks'}->{$name});
}

sub delete {
    my $self = shift;
    my $where = $self->cursor;
    return if ($self->{' zap'}->[$where]);
    $self->{' zap'}->[$where] = 1;
    $self->{' dels'}++;
}

sub undelete {
    my $self = shift;
    my $where = $self->cursor;
    return unless ($self->{' zap'}->[$where]);
    $self->{' zap'}->[$where] = undef;
    $self->{' dels'}--;
}

sub isdeleted {
    my $self = shift;
    $self->{' zap'}->[$self->cursor];
}

sub update {
    my $self = shift;
    my $fields = $self->{' fields'};
    my @ary;
    my $bind = $self->{' binding'};
    foreach (keys %$bind) {
        $self->{$_} = ${$bind->{$_}};
    }
    foreach (@$fields) {
        push(@ary, $self->{$_});
    }
    my $rs = $self->{' recs'};
    $rs->[$self->cursor] = \@ary;
}

sub next {
    my $self = shift;
    $self->fetch($self->cursor + 1);
}

sub back {
    my $self = shift;
    $self->fetch($self->cursor - 1);
}

sub bof {
   my $self = shift;
   $self->cursor <= 0;
}

sub eof {
    my $self = shift;
    $self->cursor >= $self->recs;
}

sub fields {
    my $self = shift;
    my $ref = $self->{' fields'};
    @$ref;
}

sub spawn {
    require Text::ParseWords;
    my ($self, $cmd, $pack, $unpack) = @_;
    $cmd = $ENV{'EDITOR'} || 'vi' unless ($cmd);
    $pack = "," unless ($pack);
    my $packc = ref($pack) !~ /CODE/ ?
            sub {join($pack, (map {qq!"$_"!} @_)) . "\n";} : $pack;
    $unpackc = ref($pack) !~ /CODE/ ?
            sub { my $l = scalar(<$_>); chop $l;
              Text::ParseWords::parse_line($pack, undef, $l);} : $unpack;
    my $save = $self->cursor;
    my $fn = join("-", "data_direct", $$, $0, time, localtime, rand, $gen_unique++);
    $fn =~ s/[^a-zA-Z0-9]/_/g;
    open(O, ">$fn");
    my $rs = $self->{' recs'};
    foreach (@$rs) {
        print O &$packc(@$_);
    }
    close(O);
    my @st = stat($fn);
    splice(@st, 8);
    my $s = join(":", @st);
    system "$cmd $fn";
    @st = stat($fn);
    splice(@st, 8);
    my $ss = join(":", @st);
    my $ret = undef;
    if ($s ne $ss) {
        @$rs = ();
        open(I, $fn);
        while (!eof(I)) {
            $_ = \*I;
            push(@$rs, [ &$unpackc($_) ]);
        }
        close(I);
        $ret = 1;
    }
    unlink $fn;
    $ret;
}

sub DESTROY {
    my $self = shift;
    $self->{' dbh'}->disconnect;
}

sub edit {
    require Getopt::Std;
    import Getopt::Std;
    my @dummy = map {s|^/|-|;} @ARGV;
    getopt("u:p:w:a:");
    my ($dsn, $table) = splice(@ARGV, 0, 2);
    my $d = new Data::Direct($dsn, $opt_u, $opt_p, $table, $opt_w,
         $opt_a) || die "Connection failed";
    $d->flush if ($d->spawn);
}

1;

__END__
# Documentation
=head1 NAME

Data::Direct - Perl module to emulate seqeuntial access to SQL tables

=head1 SYNOPSIS
 


=head2 In a script:


use Data::Direct;

$dd = new Data::Direct("dbi:Informix:FBI", "bill_c", 
"M0n|c4", "porn_suppliers", 
"PRICE < 99.99", 
"ORDER BY PUBLICATION_DATE" || 
die "Failed to connect";


Last two arguments can be ommitted.


	while (!$dd->eof) { 
			# Iterate over all records
	if ($dd{'LAST_MODIFIED'}) {
		$dd->delete;            
			# Mark RIP flag
		next;
	}                               
			# Change fields
	$dd->{'KILL'}++ if ($dd->{'REVENUE'} > 199.99);
	$dd->update;                    
			# Update record in memory
	$dd->next;                      
			# Goto next record
}

$dd->addnew;                            # Add a new record
$dd->{'PRICE'} = 999.99;
$dd->{'KILL'} = 0;
$dd->{'REVENUE'} = 199.99;
$dd->update;                            # Update new record in memory

$dd->flush;                             # Rewrite table



=head2 From the command prompt:

=item B<prompt %> perl -MData::Direct -e 'edit("dbi::XBase::/var/db/files", 
"contacts");'


=item B<prompt %> perl -MData::Direct -e 'edit("dbi::Oracle::CIA", 
"weapons");' /U 'bill_c' /P 'M0n1c4' 
/W "EXPIRES <= SYS_DATE()" /A "GROUP BY PRICE"




=head1 DESCRIPTION

Data::Direct selects rows from a table and lets you updated them in a
memory array. Upon calling the flush method, it erases the records from
the table and inserts them from the array.
You can supply a WHERE filter to be applied both on query and on deletion,
and additional SQL code for sorting the records.

=head1 OPTIONS

=over 4

=head2 Constructor

=item B<new>($dsn, $user, $pass, $table [, $where_clause [, $additional_select_code]]
Connects to the DBI DSN specified, using #user and $pass.
$where_clause and $additional_select_code will be added to your SQL code.
After that, reads all the records to memory.



=head2 Navigating

=item I<next>

Fetches the next record. Returns undef if gone past end.

=item I<back>

Fetches the previous record. Returns undef if gone past beginning.

=item I<eof>

Returns true if cursor is after all the records.

=item I<bof>

Simillar, checks beginning of table.

=item I<recs>

Returns the number of records in the buffer

=item I<rows>

Returns the number of records in the buffer which are not deleted.
recs and rows are not the same!

=item I<setbookmark>(B<$name>)

Sets a named bookmark, to be used for gotobookmark.

=item I<gotobookmark>(B<$name>)

Takes the cursor to the specific bookmark.

=item I<fetch>(B<$rownumber>)

Retrieve a numbered record.

=item I<cursor>

Returns the row number the cursor is at.



=head2 Manipulating records

=item I<bind>(B<$column> => B<\$var>, B<$column> => B<\$var>...)

Binds a column to a scalar, using a scalar reference.

=item I<bindsimple>($package)

Binds each column to a variable with the same name, under the package
given. Use bindsimple with no parameters to bind to the main namespace.

=item I<update>

Update record after fields have been changed by accessing the members of
the object or the bound variables.

=item I<addnew>

Add a new record and point the cursor on it.

=item I<delete>

Mark a record for deletion.

=item I<undelete>

Unmark a record for deletion.

=item I<isdeleted>

Check if a record is marked for deletion.




=head2 Automatic editing

=item I<spawn>($editor, $packing_instructions, $unpacking_instructions)

Writes a text file where every line represents a record, launch the
process $editor, then update the table with the saved file.
Records are serialized and deserialized by the code references in the last
parameters.

$dd->spawn("grep <-v> <-i> Bill", sub {join(":", @_);},
	sub {my $l = <$_>; chop $l; split(/:/, $l);});

=item I<spawn>(B<$editor>, B<$delimiter>)

Uses the string as a delimiter to serialize and deserialize records.

=item I<spawn>(B<$editor>)

Uses CSV format to serialize and deserialize records.

=item I<spawn>

Launches vi or whatever $ENV{'EDITOR'} points to as an editor.

=head1 AUTHOR

Ariel Brosh, B<schop@cpan.org>

=head1 SEE ALSO

L<DBI>.  
