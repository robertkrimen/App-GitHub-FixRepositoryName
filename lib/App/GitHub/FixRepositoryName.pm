package App::GitHub::FixRepositoryName;

use warnings;
use strict;

=head1 NAME

App::GitHub::FixRepositoryName - Fix your .git/config if you change the case of your repository

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

=cut

use File::AtomicWrite;
use App::GitHub::FindRepository;
use Path::Class;
use Carp::Clan;
use Term::Prompt qw/prompt/;
use Digest::SHA1 qw/sha1_hex/;
use File::Temp qw/tempfile/;
use Getopt::Long;
$Term::Prompt::MULTILINE_INDENT = '';

sub fix_file {
    my $self = shift;
    my $file = shift;
    
    croak "Wasn't given file to fix" unless defined $file;
    croak "Can't read file \"$file\"" unless -r $file;
    
    $file = Path::Class::File->new( $file );

    my $original_content = $file->slurp;
    my $content = $self->fix( $original_content );
    return wantarray ? ($content, $original_content) : $content;
}

sub fix {
    my $self = shift;
    my $content = shift;

    my $content_copy = ref $content eq 'SCALAR' ? $$content : $content;

    # TODO Better regexp
    $content_copy =~ s!\b(git[\@:/]+github\.com[:/]\S+)!$self->_find_right_url( $1 )!ge;

    return $content_copy;
}

sub _find_right_url {
    my $self = shift;
    my $url = shift;
    my $repository = App::GitHub::FindRepository->find( $url );
    return $repository->url;
}

sub run {
    my $self = shift;

    my ($backup_to, $no_backup, $always_yes);
    GetOptions(
        'backup-to=s' => \$backup_to,
        'no-backup' => \$no_backup,
        'always-yes|Y' => \$always_yes,
    );

    my @fix = @ARGV ? @ARGV : qw/./;
    for my $path (@fix) {
        $self->_try_to_fix_file_or_directory( $path,
            backup_to => $backup_to, no_backup => $no_backup, always_yes => $always_yes );
    }
}

sub _try_to_fix_file_or_directory {
    my $self = shift;
    my $path = shift;
    my %given = @_;

    my $silent = $given{silent};
    my $print = $silent ? sub {} : sub { print @_ };

    my $file;
    if (-d $path ) {
        if ( -d "$path/.git" ) { # The directory contains .git
            $file = "$path/.git/config"; 
        }
        elsif ( 6 == grep { -d "$path/$_" } qw/branches config hooks info objects refs/ ) { # Looks like we're actually in .git
            $file = "$path/config";
        }
        else {
            croak "Don't know how to fix directory \"$path\"";
        }
    }
    elsif (-f $file ) {
        $file = $path;
    }
    else {
        croak "Don't know how to fix path \"$path\"";
    }

    croak "Can't read file \"$file\"" unless -r $file;
    croak "Can't write file \"$file\"" unless -w _;

    if (! -s _ ) {
        carp "File \"$file\" is empty";
        return;
    }

    my ($backup_file);
    my ($content, $original_content) = $self->fix_file( $file );
    if ($content eq $original_content) {
        print "Nothing to do to \"$file\"\n" unless $silent;
        return;
    }
    else {
        $print->( $content );
        $print->( "\n" ) unless $content =~ m/\n$/;
        $print->( "---\n" );
        unless ($given{always_yes}) {
            my $Y = prompt( 'Y', "Do you want to write out the new .git/config to:\n\n$file\n\n? Y/n", 'Enter y or n', 'Y' );
            unless ($Y) {
                $print->( "Abandoning update to \"$file\"\n" );
                return;
            }
        }
        unless ( $given{no_backup} ) {
            $backup_file = $self->_backup_file( $file, to => $given{backup_to}, template => $given{backup_template} );
            $print->( "Made a backup of \"$file\" to \"$backup_file\"\n" );
        }
        File::AtomicWrite->write_file({ file => $file, input => \$content });
        $print->( "Fixup of \"$file\" complete\n" );

        $file = Path::Class::File->new( "$file" );

        return wantarray ? ($file, $backup_file) : $file;
    }
}

# TODO: Factor this out to a CPAN module
sub _backup_file {
    my $self = shift;
    my $file = shift;
    my %given = @_;

    croak "Wasn't given file to backup" unless defined $file;
    croak "Can't read file \"$file\"" unless -r $file;

    $file = Path::Class::File->new( "$file" );

    my $to = $given{to} || $file->parent;

    $to = Path::Class::Dir->new( "$to" );

    $to->mkpath unless -e $to;

    croak "Backup destination \"$to\" is not a directory (or doesn't exist)" unless -d $to;
    croak "Cannot write to backup destination \"$to\"" unless -w _; 

    my $template = $given{template} || '.backup-%basename-%date-%tmp';

    if ($template =~ m/%fullpath\b/) {
        my $value = $file.'';
        $value =~ s!/+!-!g;
        $template =~ s/%fullpath\b/$value/g;
    }

    if ($template =~ m/%basename\b/) {
        my $value = $file->basename;
        $template =~ s/%basename\b/$value/g;
    }

    my ($S, $M, $H, $d, $m, $Y) = localtime time;
    $Y += 1900;

    if ($template =~ m/%date\b/) {
        my $value = "$Y-$m-$d";
        $template =~ s/%date\b/$value/g;
    }

    if ($template =~ m/%time\b/) {
        my $value = "$H:$M:$S";
        $template =~ s/%time\b/$value/g;
    }

    my ($tmp);

    if ($template =~ m/%tmp\b/) {
        $tmp = 1;
        my $value = "XXXXXX";
        $template =~ s/%tmp\b/$value/g;
    }

    if ($template =~ m/%sha1\b/) {
        my $value = sha1_hex scalar $file->slurp;
        $template =~ s/%sha1\b/$value/g;
    }

    my ($handle, $backup_file);
    if ($tmp) {
        ($handle, $backup_file) = tempfile( $template, DIR => "$to", UNLINK => 0 );
    }
    else {
        $backup_file = $to->file( $template );
        $handle = $backup_file->openw or croak "Couldn't open \"$backup_file\": since $!";
    }

    $handle->print( scalar $file->slurp );
    close $handle;

    my $file_size = -s $file;
    my $backup_file_size = -s $backup_file;

    croak "Couldn't backup \"$file\" ($file_size) to \"$backup_file\" ($backup_file_size): size doesn't match!" unless $file_size == $backup_file_size;

    return Path::Class::File->new( $backup_file );
}

=head1 AUTHOR

Robert Krimen, C<< <rkrimen at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-app-github-fixrepositoryname at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=App-GitHub-FixRepositoryName>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc App::GitHub::FixRepositoryName


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=App-GitHub-FixRepositoryName>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/App-GitHub-FixRepositoryName>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/App-GitHub-FixRepositoryName>

=item * Search CPAN

L<http://search.cpan.org/dist/App-GitHub-FixRepositoryName/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2009 Robert Krimen, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

__PACKAGE__; # End of App::GitHub::FixRepositoryName
