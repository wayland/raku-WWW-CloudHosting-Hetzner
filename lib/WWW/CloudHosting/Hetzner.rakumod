use	Cro::HTTP::Client;
use	JSON::Fast;

class	WWW::CloudHosting::Hetzner {
	has	Str			$.token;
	has	Cro::HTTP::Client	$!client;

	submethod BUILD(:$!token) {
		$!client = Cro::HTTP::Client.new(base-uri => 'https://api.hetzner.cloud/v1/');
	}

	method	auth-header() {
		return Authorization => "Bearer $!token";
	}

	method list-servers(--> Promise) {
		start {
			my $resp = await $!client.get('servers', headers => [self.auth-header]);
			return await $resp.body if $resp.status == 200;
			die "Failed to list servers: $resp.status";
		}
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

	method create-server(*%payload --> Promise) {
		start {
			my $resp = await $!client.post("servers",
				headers => [self.auth-header, 'Content-Type' => 'application/json'],
				body    => %payload.&to-json
			);

			$resp.status == 201
				?? await $resp.body 
				!! do {
					say "Create failed: status $resp.status";
					say await $resp.body;
					die "Failed to create server";
				}
		}
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

	method list-images(*%payload --> Promise) {
		start {
			my $resp = await $!client.get('images', 
				headers => [self.auth-header],
				query    => %payload,
			);
			if $resp.status == 200 {
				await $resp.body
			} else {
				say "List images failed: status $resp.status";
				say await $resp.body;
				die "Failed to list images";
			}
		}
	}
}
