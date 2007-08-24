package WWW::Metaweb;

use 5.008006;
use strict;
use warnings;

use JSON;
use LWP::UserAgent;
use URI::Escape;

# debugging
use Data::Dumper;

our $VERSION = '0.01';
our $errstr = '';

=head1 NAME

WWW::Metaweb - An interface to the Metaweb database via MQL

=head1 SYNOPSIS

  use strict;
  use WWW::Metaweb;

  my $mh = WWW::Metaweb->new( username => $u,
  			      password => $p, 
			      server => 'www.freebase.com',
			      auth_uri => '/api/account/login',
			      read_uri => '/api/service/mqlread',
			      write_uri => '/api/service/mqlwrite',
			      trans_uri => '/api/trans',
			      pretty_json => 1 );

  my $query = {
	  name => 'Nico Minoru',
	  id => undef,
	  type => [],
	  '/comic_books/comic_book_character/cover_appearances' => [{
		  name => undef,
		  id => undef,
	  }]
  };

  $mh->add_query('read', $query);
  $mh->send_envelope('read')
    or die $WWW::Metaweb::errstr;

  my $result = $mh->result('read', 'json');
  print $result . "\n";

=head1 ABSTRACT

Metaweb provides an interface to a Metaweb database through it's HTTP API and MQL.

=head1 DESCRIPTION

WWW::Metaweb provides an interface to a Metaweb database instance. The best example currently is Freebase (www.freebase.com). Queries to a Metaweb are made through HTTP requests to the Metaweb API.

Qeueries are written in the Metaweb Query Language (MQL), using Javascript Object Notation (JSON). WWW::Metaweb allows you to write the actual JSON string yourself or provide a Perl array ref / hash ref structure to be converted to JSON.

=head1 METHODS

=head2 Class methods

=head3 $version = WWW::Metaweb->version

=cut

sub version  {
	return $WWW::Metaweb::VERSION;
} # ->version

=head2 Constructors

=cut

=head3 $mh = WWW::Metaweb->connect(username => $u, password => $p [, option_key => 'option_value'])

While this method no longer requires a username and password, if they are supplied by are incorrect (or Metaweb can't authenticate for any other reason) then C<undef> will be returned.

=cut

sub connect  {
	my $invocant = shift;
	my $class = ref($invocant) || $invocant;
	my ($username, $password);


	my $options = { @_ };
	$username = $options->{username};
	$password = $options->{password};

	my $self = {
		     auth_uri => undef,
		     read_uri => undef,
		     write_uri => undef,
		     trans_uri => undef,
		     read_envelope => { },
		     write_envelope => { },
		     result_envelope => { },
		     pretty_json => 0
		   };
	
	bless $self, $class;
	
	# Sets the option attributes from $options into $self.
	foreach my $key (keys %$options)  {
		$self->{$key} = $options->{$key} if (exists $self->{$key});
	}
	$self->server($options->{server}); # Sets the server.

	# A little bit of vanity here (the agent).
	$self->useragent(LWP::UserAgent->new( agent => 'Metaweb/'.$WWW::Metaweb::VERSION,
					      timeout => 10)
			);

	# Attempt to authenticate if $username and $password are defined.
	# As far as Freebase goes this is a required step right now.
	if (defined $username && defined $password)  {
		$self = undef unless ($self->authenticate($username, $password));
	}

	return $self;
} # ->connect

=head2 Authentication

=head3 $mh->authenticate($username, $password)

Authenticates to the auth_uri using the supplied username and password. If the authentication is successful then the cookie is retained for future queries.

In the future this method may give the option to accept a cookie instead of username and password.

=cut

sub authenticate  {
	my $self = shift;
	my ($username, $password) = @_;
	my ($response, $raw_header, $credentials, @cookies);
	my $login_url = $self->server.$self->{auth_uri};


	$response = $self->useragent->post($login_url, { username => $username,
						       	 password => $password
						       });
	# This would indicate some form of network problem (such as the server
	# being down).
	unless ($response->is_success)  {
		$WWW::Metaweb::errstr = 'Authentication HTTP request failed: ' . $response->status_line;
		return undef;
	}

	unless ($raw_header = $response->header('Set_Cookie'))  {
		# Authentication failed.
		my $json = JSON->new;
		my $reply = $json->jsonToObj($response->content);
		$WWW::Metaweb::errstr = "Login failed: [status: $reply->{status}, code: $reply->{code}]";
		
		return undef;
	}
	@cookies = split /,\s+/, $raw_header;
	$credentials = '';
	my $crumb_count = 0;
	foreach my $cookie (@cookies)  {
		my @crumbs = split ';', $cookie;
		$credentials .= ';';
		$credentials .= $crumbs[0];
	}

	$self->useragent->default_header('Cookie' => $credentials);
	$self->{authenticated} = 1;

	return 1;
} # ->authenticate

=head2 Query manipulation

=head3 $mh->add_query($method, query_name1 => $query1 [, query_name2 => $query2 [, ...]])

This method adds queries to a query envelope. C<$method> must have a value of either 'read' or 'write'.

Each query must have a unique name, otherwise a new query will overwrite an old one. By the same token, if you wish to change a query in the query envelope, simply specify a new query with the old query name to overwrite the original.

A query may either be specified as a Perl structure, or as a JSON string. The first example below is a query as a Perl structure.

  $query_perl = {
	  name => "Nico Minoru",
	  id => undef,
	  type => [],
	  '/comic_books/comic_book_character/cover_appearances' => [{
		name => null  
	  }]
  };

The same query as a JSON string:

  $query_json = '
  {
	  "name":"Nico Minoru",
	  "id":null,
	  "type":[],
	  "/comic_books/comic_book_character/cover_appearances":[{
		  "name":null
	  }]
  }';

For the same of completeness this JSON query can be submitted the same way as in the query editor, a shortened version formatted like this is below:

  $query_json_ext = '
  {
	  "query":{
		  "name":"Nico Minoru",
		  "type":[]
	  }
  }';

Now we can add all three queries specified above to the envelope with one call.

  $mh->add_query( query_perl => $query_perl, query_json => $query_json, query_json_ext => $query_json_ext );

=cut

sub add_query  {
	my $self = shift;
	my $method = shift;
	my ($envelope, $queries);

	return undef unless $envelope = __test_envelope($method, 'add_query');

	if (@_ == 1)  {
		my $query = shift;
		$queries = { netmetawebquery => $query };
	}
	elsif (@_ > 1 && (@_ % 2) == 0)  {
		$queries = { @_ };
	}
	else  {
		$WWW::Metaweb::errstr = "Query name found with missing paired query. You probably have an odd number of query names and queries.";
		return undef;
	}

	my $no_error = 1;	
	foreach my $query_name (keys %$queries)  {
		$no_error = 0 unless $self->check_query_syntax($method, $queries->{$query_name});
		$self->{$envelope}->{$query_name} = $self->perl_query($queries->{$query_name});
	}

	return $no_error;
} # ->add_query

=head3 $mh->clear_queries($method)

Clears all the previous queries from the envelope.

C<$method> must be either 'read' or 'write'.

=cut

sub clear_queries  {
	my $self = shift;
	my $method = shift;
	my $envelope;

	return undef unless $envelope = __test_envelope($method, 'clear_envelope');

	$self->{$envelope} = { };

	return 1;
} # ->clear_queries

=head3 $count = $mh->query_count($method)

Returns the number of queries held in the C<$method> query envelope.

=cut

sub query_count  {
	my $self = shift;
	my $method = shift;
	my ($envelope, @keys, $key_count);

	return undef unless $envelope = __test_envelope($method, 'query_count');
	@keys = keys %{$self->{$envelope}};
	#print Dumper $self->{$envelope};
	$key_count = @keys;
	
	return $key_count; 
} # ->query_count

=head3 $bool = $mh->check_query_syntax($method, $query)

Returns a boolean value to indicate whether the query provided (either as a Perl structure or a JSON string) follows correct MQL syntax. C<$method> should be either 'read' or 'write' to indicate which syntax to check query against.

Note: This method has not yet been implemented, it will always return TRUE.

=cut

sub check_query_syntax  {
	my $self = shift;
	my $method = shift;
	my $query = shift;

	return 1;
} # ->check_query_syntax

=head3 $obj = $mh->perl_query($query)

Forces a query into a Perl structure if it's a JSON string. If given a Perl structure it is left more or less alone.

=cut

sub perl_query  {
	my $self = shift;
	my $original_query = shift;
	my ($format, $json_string, $perl_query);
	my $json = JSON->new;

	if (ref $original_query)  {
		$format = 'perl';
		$json_string = $json->objToJson($original_query);
	}
	else  {
		$format = 'json';
		$json_string = $original_query;

	}

	$perl_query = {
			query => $json->jsonToObj($json_string),
			format => $format
		     };
	
	if (keys %{$perl_query->{query}} == 1 && defined $perl_query->{query}->{query})  {
		$perl_query->{query} = $perl_query->{query}->{query};
	}

	return $perl_query;
} # ->perl_query

=head3 $http_was_successful = $mh->send_envelope($method)

Sends the current query envelope and returns whether the HTTP portion was successful. This does not indicate that the query itself was well formed or correct.

C<$method> must be either 'read' or 'write'.

=cut

sub send_envelope  {
	my $self = shift;
	my $method = shift;
	my $envelope;

	return undef unless $envelope = __test_envelope($method, 'send_envelope');

	my $json = JSON->new;
	my ($url, $response);
	my $json_envelope = $json->objToJson($self->{$envelope});
	$json_envelope =~ s/"format":"(?:json|perl),"//g;

	$url = $self->server.$self->{$method.'_uri'}.'?queries='.uri_escape($json_envelope);

	$response = $self->useragent->get($url);

	unless ($response->is_success)  {
		$WWW::Metaweb::errstr = "Query failed, HTTP response: " . $response->status_line;
		return undef;
	}
	
	return ($self->set_result($method, $response->content)) ? $response->is_success : undef;
} # ->send_envelope

=head2 Query Convenience Methods

As most of the query and result methods require a C<$method> argument as the first parameter, I've included methods to call them for each method explicitly.

If you know that you will always be using a method call for either a read or a write query/result, then it's safer to user these methods as you'll get a compile time error if you spell read or write incorrectly (eg. a typo), rather than a run time error.

=head3 $mh->add_read_query(query_name1 => $query1 [, query_name2 => $query2 [, ...]])

Convenience method to add a read query. See add_query() for details.

=cut

sub add_read_query  {
	my $self = shift;

	return $self->add_query('read', @_);
} # ->add_read_query

=head3 $mh->add_write_query(query_name1 => $query1 [, query_name2 => $query2 [, ...]])

Convenience method to add a write query. See add_query() for details.

=cut

sub add_write_query  {
	my $self = shift;

	return $self->add_query('write', @_);
} # ->add_write_query

=head3 $mh->clear_read_queries

Convenience method to clear the read envelope. See clear_queries() for details.

=cut

sub clear_read_queries  {
	my $self = shift;

	return $self->clear_queries('read', @_);
} # ->clear_read_queries

=head3 $mh->clear_write_queries

Convenience method to clear the write envelope. See clear_queries() for details.

=cut

sub clear_write_queries  {
	my $self = shift;

	return $self->clear_queries('write', @_);
} # ->clear_write_queries

=head3 $count = $mh->read_query_count

Convenience method, returns the number of queries in the read envelope. See query_count() for details.

=cut

sub read_query_count  {
	my $self = shift;

	return $self->query_count('read', @_);
} # ->read_query_count

=head3 $count = $mh->write_query_count

Convenience method, returns the number of queries in the write envelope. See query_count() for details.

=cut

sub write_query_count  {
	my $self = shift;

	return $self->query_count('write', @_);
} # ->write_query_count

=head3 $http_was_successful = $mh->send_read_envelope

Convenience method, sends the read envelope. See send_envelope() for details.

=cut

sub send_read_envelope  {
	my $self = shift;

	return $self->send_envelope('read');
} # ->send_read_envelope

=head3 $http_was_successful = $mh->send_write_envelope

Convenience method, sends the write envelope. See send_envelope() for details.

=cut

sub send_write_envelope  {
	my $self = shift;

	return $self->send_envelope('write');
} # ->send_write_envelope


=head2 Result manipulation

=head3 $mh->set_result($json)

Sets the result envelope up so that results can be accessed for the latest query. Any previous results are destroyed.

This method is mostly used internally.

=cut

sub set_result  {
	my $self = shift;
	my $method = shift;
	my $json_result = shift;
	my $json = JSON->new;
	my $envelope;

	return undef unless $envelope = __test_envelope($method, 'set_result');
	
	$self->{result_envelope} = $json->jsonToObj($json_result);

	# Potential bug here if an error occurs
	foreach my $query_name (keys %{$self->{result_envelope}})  {
		$self->{result_envelope}->{$query_name}->{format} = $self->{$envelope}->{$query_name}->{format} unless ($query_name eq 'status' || $query_name eq 'code');
	}

	unless ($self->{result_envelope}->{status} eq '200 OK')  {
		$WWW::Metaweb::errstr = 'Bad outer envelope status: ' . $self->{result_envelope}->{status};
		return 0;
	}

	return 1;
} # ->set_result

=head3 $bool = $mh->result_is_ok($query_name)

Returns a boolean result indicating whether the query named C<$query_name> returned a status ok. Returns C<undef> if there is no result for C<query_name>.

=cut

sub result_is_ok  {
	my $self = shift;
	my $query_name = shift || 'netmetawebquery';
	my $result_is_ok = undef;

	if (defined $self->{result_envelope}->{$query_name})  {
		if ($self->{result_envelope}->{$query_name}->{code} eq '/api/status/ok')  {
			$result_is_ok = 1;
		}
		else  {
			$WWW::Metaweb::errstr = 'Result status not okay: ' . $self->{result_envelope}->{$query_name}->{code};
			$result_is_ok =  0;
		}
	}
	else  {
		$WWW::Metaweb::errstr = 'No result found for query name: ' . $query_name;
		$result_is_ok = undef;
	}

	return $result_is_ok;
} # ->result_is_okay

=head3 $mh->result($query_name [, $format])

Returns the result of query named C<$query_name> in the format C<$format>, which should be either 'perl' for a Perl structure or 'json' for a JSON string.

if C<$query_name> is not defined then the default query name 'netmetawebquery' will be used instead.

If C<$format> is not specified then the result is returned in the format the original query was supplied.

Following the previous example, we have three separate results stored, so let's get each of them out.

  $result1 = $mh->result('query_perl');
  $result2 = $mh->result('query_json');
  $result3 = $mh->result('query_json_ext', 'perl');

The first two results will be returned in the format their matching queries were submitted in - Perl structure and JSON string respectively - the third will be returned as a Perl structure, as it has been explicitly asked for in that format.

Fetching a result does not effect it, so a result fetched in one format can be later fetched using another.

=cut

sub result  {
	my $self = shift;
	my $query_name = shift || 'netmetawebquery';
	my $format = shift;
	my $result;

	unless (defined $self->{result_envelope}->{$query_name})  {
		$WWW::Metaweb::errstr = "No result found with the name: $query_name";
		return undef;
	}
	$format = $self->{result_envelope}->{$query_name}->{format} unless defined $format;

	if ($format eq 'json')  {
		my $json = JSON->new;
		$result = $json->objToJson($self->{result_envelope}->{$query_name}->{result}, { pretty => $self->{pretty_json} });
	}
	else  {
		$result = $self->{result_envelope}->{$query_name}->{result};
	}

	return $result;
} # ->result

=head2 Translations

=cut

=head3 $content = $mh->trans($translation, $guid)

Gets the content for a C<guid> in the format specified by C<$translation>. WWW::Metaweb currently supports the translations C<raw>, C<image_thumb> and C<blurb>.

C<$translation> is not checked for validity, but an error will most likely be returned by the server.

C<$guid> should be the global identifier of a Metaweb object of type C</common/image> or C</type/content> and/or C</common/document> depending on the translation requested, if not the Metaweb will return an error. The global identifier can be prefixed with either a '#' or the URI escaped version '%23' then followed by the usual string of lower case hex.

=cut

sub trans  {
	my $self = shift;
	my $translation = shift;
	my $guid = lc shift;
	my ($url, $response);

	# Check that the guid looks mostly correct and replace a hash at the
	# beginning of the guid with the URI escape code.
	unless ($guid =~ s/^(\#|\%23)([\da-f]+)$/\%23$2/)  {
		$WWW::Metaweb::errstr = "Bad guid: $guid";
		return undef;
	}

	$url = $self->server.$self->{trans_uri}.'/'.$translation.'/'.$guid;
	$response = $self->useragent->get($url);
	
	# An HTTP response that isn't success indicates something bad has
	# happened and there's nothing I can do about it.
	unless ($response->is_success)  {
		$WWW::Metaweb::errstr = "Trans query failed, HTTP response: " . $response->status_line;
		return undef;
	}

	return $response->content;
} # ->trans

=head3 $content = $mh->raw($guid)

Convenience method for getting a C<raw> translation of the object with C<$guid>. See C<trans> for more details.

=cut

sub raw  {
	my $self = shift;
	my $guid = shift;

	return $self->trans('raw', $guid);
} # ->raw

=head3 $content = $mh->image_thumb($guid)

Convenience method for getting a C<image_thumb> translation of the object with C<$guid>. See C<trans> for more details.

=cut

sub image_thumb  {
	my $self = shift;
	my $guid = shift;

	return $self->trans('image_thumb', $guid);
} # ->image_thumb

=head3 $content = $mh->blurb($guid)

Convenience method for getting a C<blurb> translation of the object with C<$guid>. See C<trans> for more details.

=cut

sub blurb  {
	my $self = shift;
	my $guid = shift;

	return $self->trans('blurb', $guid);
} # ->blurb

=head2 Accessors

=cut

=head3 $ua = $mh->useragent
=head3 $mh->useragent($ua)

Gets or sets the LWP::UserAgent object which is used to communicate with the Metaweb. This method can be used to change the user agent settings (eg. C<$mh->useragent->timeout($seconds)>).

=cut

sub useragent  {
	my $self = shift;
	my $new_useragent = shift;

	$self->{ua} = $new_useragent if defined $new_useragent;

	return $self->{ua};
} # ->useragent

=head3 $host = $mh->server
=head3 $mh->server($new_host)

Gets or sets the host for this Metaweb (eg. www.freebase.com). No checking is currently done as to the validity of this host.

=cut

sub server  {
	my $self = shift;
	my $new_server = shift;
	
	$self->{server} = $new_server if defined $new_server;
	$self->{server} = 'http://'.$self->{server} unless $self->{server} =~ /^http:\/\//;

	return $self->{server};
} # ->server


=head1 ATTRIBUTES

The following attributes can be set manually by the programmer.

=head2 WWW::Metaweb set-up

=head3 auth_uri

The URI used to authenticate for this Metaweb (eg. /api/account/login).

=head3 read_uri

The URI used to submit a read MQL query to this Metaweb (eg. /api/service/mqlread).

=head3 write_uri

The URI used to submit a write MQL query to this Metaweb (eg. /api/service/mqlwrite).

=head3 trans_uri

The URI used to access the translation service for this Metaweb (eg. /api/trans). Please note this this URI does not include the actual C<translation>, at this time these are C<raw>, C<image_thumb> and C<blurb>.

=head2 Formatting

=head3 pretty_json

Determines whether the response to a JSON query is formatted nicely. This is just passed along to the JSON object as C<JSON->new(pretty => $mh->{pretty})>.

=head1 BUGS AND TODO

Still very much in development. I'm waiting to hear from you.

There is not query syntax checking - the method exists, but doesn't actually do anything.

If authentication fails not much notice is given.

More information needs to be given when a query fails.

I would like to implement transparent cursors in read queries so a single query can fetch as many results as exist (rather than the standard 100 limit).

=head1 ACKNOWLEDGEMENTS

While entirely rewritten, I think it's only fair to mention that the basis for the core of this code is the Perl example on Freebase (http://www.freebase.com/view/helptopic?id=%239202a8c04000641f800000000544e139).

=head1 SEE ALSO

Freebase, Metaweb

=head1 AUTHORS

Hayden Stainsby E<lt>hds@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007 by Hayden Stainsby

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut

################################################################################
# Below here are private functions - so no POD for here.

# __test_envelope
# Tests that an envelope is either 'read' or 'write'. If it is, '_envelope' is
# appended and returned. If not, undef is returned and an error message is set.
sub __test_envelope  {
	my $envelope = shift;
	my $method = shift;

	if ($envelope eq 'read' || $envelope eq 'write')  {
		$envelope .= '_envelope';
	}
	else  {
		$WWW::Metaweb::errstr = "Envelope must have a value of 'read' or 'write' in $method()";
		$envelope = undef;
	}

	return $envelope;
} # &__test_envelope



return 1;
__END__


