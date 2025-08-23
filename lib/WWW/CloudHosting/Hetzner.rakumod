unit module WWW::CloudHosting::Hetzner;

use	Cro::HTTP::Client;
use	JSON::Fast;
use     Hash::Merge;
use	Env::Dotenv :ALL;

class	Client {
	has	Str			$.token;
	has	Cro::HTTP::Client	$!client;

	submethod BUILD(Str :$!token) {
		dotenv_load();
		$!token or %*ENV<HETZNER_TOKEN> or die "Missing HETZNER_TOKEN";
		$!token or $!token = %*ENV<HETZNER_TOKEN>;
		$!client = Cro::HTTP::Client.new(base-uri => 'https://api.hetzner.cloud/v1/');
	}

	method	auth-header() {
		return Authorization => "Bearer $!token";
	}

	method get-server(Int $id --> Promise) {
		start {
			my $resp = await $!client.get("servers/$id", headers => [self.auth-header]);
			return await $resp.body if $resp.status == 200;
			die "Failed to get server $id: $resp.status";
		}
	}

	method server-action(Int $id, Str $action, %payload? --> Promise) {
		start {
			my $resp = await $!client.post("servers/$id/actions/$action",
				headers => [self.auth-header, 'Content-Type' => 'application/json'],
				body => %payload ?? %payload.&to-json !! '{}'
			);
			return await $resp.body if $resp.status == 201;
			die "Action '$action' on server $id failed: $resp.status";
		}
	}

	method reboot-server(Int $id --> Promise) {
		self.server-action($id, 'reboot');
	}

	method poweroff-server(Int $id --> Promise) {
		self.server-action($id, 'poweroff');
	}

	method poweron-server(Int $id --> Promise) {
		self.server-action($id, 'poweron');
	}

	method shutdown-server(Int $id --> Promise) {
		self.server-action($id, 'shutdown');
	}

	method delete-server(Int $id --> Promise) {
		start {
			my $resp = await $!client.delete("servers/$id", headers => [self.auth-header]);

			given $resp.status {
				when 200..299 {
					"Server $id deleted successfully ({$_})"
				}
				default {
					say "Delete failed: status $resp.status";
					say await $resp.body;
					die "Failed to delete server $id";
				}
			}
			await $resp.body;
		}
	}

	method create-server(Bool :$fail-on-exists = True, *%payload --> Promise) {
		start self.create-action(
			'create', 'server', 
			'servers',
			:$fail-on-exists,
			|%payload,
		);
	}

	method create-snapshot(Str $server-id, Str $description --> Promise) {
		start self.create-action(
			'create', 'snapshot',
			"servers/{$server-id}/actions/create_image",
			# payload
			type        => 'snapshot',
			description => $description,
			pull-key    => 'image',
		);
	}

	# Note: It's tempting to try to move the "start" into this function, 
	# but it doesn't work, because you can't return from a "start" block
	method create-action(
		$action, $object, $url-part,
		Bool :$fail-on-exists = True,
		Str :$pull-key is copy,
		*%payload
		--> Hash
	) {
		$pull-key or $pull-key = $object;
		# say %payload.&to-json;
		my $response = await $!client.post($url-part,
			headers => [self.auth-header, 'Content-Type' => 'application/json'],
			body    => %payload.&to-json
		);
		given $response.status {
			when 200..299 {
				"Successfully ({$_}) performed action $action on $object"
			}
			default {
				say "$action failed: status {$response.status}";
				say await $response.body;
				die "Failed to $action $object";
			}
		}
		my $response-body = await $response.body;
		$response-body = $response-body{$pull-key};
		$response-body<action> = $action;
		return $response-body;
		CATCH {
			when X::Cro::HTTP::Error {
				my $response-body = await .response.body;
				if ! $fail-on-exists and $response-body<error><code> eq 'uniqueness_error' {
					my $items = await self.list-action($url-part, name => %payload<name>);
					$response = $items{$url-part}[0];
					$response<action> = 'use';
					return $response;
				} else {
					say "$action failed: status {.response.status}";
					say $response-body;
					.rethrow();
				}
			}
		}
	}

	method list-action(Str $url-part, *%query --> Promise) {
		start {
			CATCH {
				when X::Cro::HTTP::Error {
					say "List action failed: status {.response.status}";
					say await .response.body;
					die "Failed to list from $url-part";
				}
			}

			my $resp = await $!client.get(
				$url-part,
				headers => [self.auth-header],
				query   => %query,
			);

			if $resp.status == 200 {
				await $resp.body
			} else {
				say "List $url-part failed: status $resp.status";
				say await $resp.body;
				die "Failed to list $url-part";
			}
		}
	}

	method list-images(*%query --> Promise) {
		self.list-action('images', |%query);
	}

	method list-servers(*%query --> Promise) {
		self.list-action('servers', |%query);
	}

	method get-full-configs(%configs) {
		my %full-configs;
		for %configs<servers>.kv -> $server-name, $server-config {
			# Merge appropriate config into $full-config
			my $full-config = merge-hashes(
				$server-config,
				%configs<datacentres>{$server-config<datacentre>},
				%configs<server-categories>{$server-config<server-category>},
			);
			$full-config<environment-name> = %configs<environment-name>;

			# New server name should be <environment>--<category>--<name>
			$full-config<full-server-name> = <environment-name name-prefix name>.map({ $full-config{$_} }).join('--');

			# Save $full-config into return value
			%full-configs{$full-config<full-server-name>} = $full-config;
		}
		return %full-configs;
	}
}
