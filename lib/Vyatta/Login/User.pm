# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
#
# **** End License ****

package Vyatta::Login::User;
use strict;
use warnings;
use lib "/opt/vyatta/share/perl5";
use Vyatta::Config;
use Vyatta::Misc;

# Exit codes form useradd.8 man page
my %reasons = (
    0  => 'success',
    1  => 'can´t update password file',
    2  => 'invalid command syntax',
    3  => 'invalid argument to option',
    4  => 'UID already in use (and no -o)',
    6  => 'specified group doesn´t exist',
    9  => 'username already in use',
    10 => 'can´t update group file',
    12 => 'can´t create home directory',
    13 => 'can´t create mail spool',
);

# Construct a map from existing users to group membership
sub get_groups {
    my %group_map;

    setgrent();
    while ( my ( $name, undef, undef, $members ) = getgrent() ) {
        foreach my $user ( split / /, $members ) {
            $group_map{$user} = [] unless ( $group_map{$user} );
            my $g = $group_map{$user};
            push @$g, $name;
        }
    }
    endgrent();

    return \%group_map;
}

my $levelFile = "/opt/vyatta/etc/level";

# Convert level to additional groups
sub _level2groups {
    my $level = shift;
    my @groups;

    open( my $f, '<', $levelFile )
      or return;

    while (<$f>) {
        chomp;
        next unless $_;

        my ( $l, $g ) = split /:/;
        if ( $l eq $level ) {
            @groups = split( /,/, $g );
            last;
        }
    }
    close $f;
    return @groups;
}

# protected users override file
my $protected_users = '/opt/vyatta/etc/protected-user';

# Users who MUST not use vbash
sub _protected_users {
    my @protected;

    open my $pfd, '<', $protected_users
      or return;

    while (<$pfd>) {
        chomp;
        next unless $_;

        push @protected, $_;
    }
    close($pfd);
    return @protected;
}

# make list of vyatta users (ie. users of vbash)
sub _vyatta_users {
    my @vusers;

    setpwent();

    # ($name,$passwd,$uid,$gid,$quota,$comment,$gcos,$dir,$shell,$expire)
    #   = getpw*
    while ( my ($name, undef, undef, undef, undef, undef,
		undef, undef, $shell) = getpwent() ) {
        push @vusers, $name if ( $shell eq '/bin/vbash' );
    }
    endpwent();

    return @vusers;
}

sub set_authorized_keys {
    my $user   = shift;
    my $config = new Vyatta::Config;
    $config->setLevel("system login user $user authentication public-keys");

    my @keys = $config->listNodes();
    return unless @keys;

    # ($name,$passwd,$uid,$gid,$quota,$comment,$gcos,$dir,$shell,$expire)
    #   = getpw*
    my ( undef, undef, $uid, $gid, undef, undef, undef, $home ) =
      getpwnam($user);
    return unless $home;
    return unless -d $home;

    my $sshdir = "$home/.ssh";
    unless ( -d $sshdir ) {
        mkdir $sshdir;
        chown( $uid, $gid, $sshdir );
        chmod( 0750, $sshdir );
    }

    open( my $auth, '>', "$sshdir/authorized_keys" );
    unless ($auth) {
        warn "open $sshdir/authorized_keys failed: $!";
        return;
    }

    print {$auth} "# Automatically generated by Vyatta configuration\n";
    print {$auth} "# Do not edit, all changes will be lost\n";
    foreach my $name (@keys) {
        my $type = $config->returnValue("$name type");
        my $key  = $config->returnValue("$name key");
        print {$auth} "$type $key $name\n";
    }

    close $auth;
    chmod( 0640, "$sshdir/authorized_keys" );
}

sub update {
    my $membership = get_groups();
    my $uconfig    = new Vyatta::Config;
    $uconfig->setLevel("system login user");
    my %users = $uconfig->listNodeStatus();

    die "All users deleted!\n" unless %users;

    foreach my $user ( keys %users ) {
        my $state = $users{$user};
        if ( $state eq 'deleted' ) {
            if ( $user eq 'root' ) {
                warn "Disabling root account, instead of deleting\n";
                system('sudo usermod -p ! root') == 0
                  or die "usermod of root failed: $?\n";
            } elsif ( getlogin() eq $user ) {
                die "Attempting to delete current user: $user\n";
            } else {

                # This logs out user
                system("sudo pkill -u $user");

                system("sudo userdel -r '$user'") == 0
                  or die "userdel of $user failed: $?\n";
            }
            next;
        }

        next unless ( $state eq 'added' || $state eq 'changed' );

        $uconfig->setLevel("system login user $user");
        my $pwd = $uconfig->returnValue('authentication encrypted-password');

        unless ($pwd) {
            warn "Encrypted password not in configuration for $user";
            next;
        }

        my $level = $uconfig->returnValue('level');
        unless ($level) {
            warn "Level not defined for $user";
            next;
        }

        # map level to group membership
        my @new_groups = _level2groups($level);

        # add any additional groups from configuration
        push( @new_groups, $uconfig->returnValues('group') );

        my $fname = $uconfig->returnValue('full-name');
        my $home  = $uconfig->returnValue('home-directory');

        # Read existing settings
        my (
            undef,    $opwd, $uid, $gid,   undef,
            $comment, undef, $dir, $shell, undef
        ) = getpwnam($user);

        my $old_groups = $membership->{$user};

        my $og_str =
          ( defined($old_groups) ) ? ( join( ' ', sort @$old_groups ) ) : '';
        my $ng_str = join( ' ', sort @new_groups );

        # not found in existing passwd, must be new
        my $cmd;
        unless ( defined($uid) ) {

            # make new user using vyatta shell
            #  and make home directory (-m)
            #  and with default group of 100 (users)
            $cmd = 'useradd -s /bin/vbash -m -N';
        } else {
            if (   $opwd eq $pwd
                && ( !$fname || $fname eq $comment )
                && ( !$home  || $home  eq $dir )
                && $og_str eq $ng_str )
            {

                # If no part of password or group file changed
                # then there is nothing to do here.
            } else {
                $cmd = "usermod";
            }
        }

        if ($cmd) {
            $cmd .= " -p '$pwd'";
            $cmd .= " -c \"$fname\"" if ( defined $fname );
            $cmd .= " -d \"$home\"" if ( defined $home );
            $cmd .= ' -G ' . join( ',', @new_groups );
            system("sudo $cmd $user");

            unless ( $? == 0 ) {
                my $reason = $reasons{ ( $? >> 8 ) };
                die "Attempt to change user $user failed: $reason\n";
            }
        }

        set_authorized_keys($user);
    }

    # Remove any vyatta users that do not exist in current configuration
    # This can happen if user added but configuration not saved
    my %protected = map { $_ => 1 } _protected_users();
    foreach my $user ( _vyatta_users() ) {
        next if $protected{$user};
        next if defined $users{$user};

        warn "User $user not listed in current configuration\n";
        system("sudo userdel --remove $user") == 0
          or die "Attempt to delete user $user failed: $!";
    }
}

1;
