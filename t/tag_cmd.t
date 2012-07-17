#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 25;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use File::Path qw(make_path remove_tree);
use URI;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::tag';

ok my $sqitch = App::Sqitch->new(
    uri     => URI->new('https://github.com/theory/sqitch/'),
    top_dir => Path::Class::Dir->new('sql'),
), 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $tag = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'tag',
    config  => $config,
}), $CLASS, 'tag command';

can_ok $CLASS, qw(
    options
    configure
    message
    execute
);

is_deeply [$CLASS->options], [qw(
    message|m=s@
)], 'Should have no options';

make_path 'sql';
END { remove_tree 'sql' };

my $plan = $sqitch->plan;
ok $plan->add( name => 'foo' ), 'Add change "foo"';

ok $tag->execute('alpha'), 'Tag @alpha';
is $plan->get('@alpha')->name, 'foo', 'Should have tagged "foo"';
ok $plan->load, 'Reload plan';
is $plan->get('@alpha')->name, 'foo', 'New tag should have been written';
is [$plan->tags]->[-1]->comment, '', 'New tag should have empty comment';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag}',
        change => 'foo',
        tag    => '@alpha',
    ]
], 'The info message should be correct';

# With no arg, should get a list of tags.
ok $tag->execute, 'Execute with no arg';
is_deeply +MockOutput->get_info, [
    ['@alpha'],
], 'The one tag should have been listed';

# Get a list of tags.
ok $plan->tag( name => '@beta' ), 'Add tag @beta';
ok $tag->execute, 'Execute with no arg again';
is_deeply +MockOutput->get_info, [
    ['@alpha'],
    ['@beta'],
], 'Both tags should have been listed';

# Set a message.
isa_ok $tag = App::Sqitch::Command::tag->new({
    sqitch  => $sqitch,
    message => [qw(hello there)],
}), $CLASS, 'tag command with message';

ok $tag->execute( 'gamma' ), 'Tag @gamma';
is $plan->get('@gamma')->name, 'foo', 'Gamma tag should be on change "foo"';
is [$plan->tags]->[-1]->comment, "hello\n\nthere", 'Gamma tag should have comment';
ok $plan->load, 'Reload plan';
is $plan->get('@gamma')->name, 'foo', 'Gamma tag should have been written';
is [$plan->tags]->[-1]->comment, "hello\n\nthere", 'Written tag should have comment';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag}',
        change => 'foo',
        tag    => '@gamma',
    ]
], 'The gamma message should be correct';
