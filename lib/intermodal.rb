require "intermodal/version"
require "yaml"

module Intermodal
  def self.template_dir
    Pathname.new(__FILE__).join("..", "templates")
  end

  def self.detect(path)
    gemfile = path.join("Gemfile")

    if File.exists? gemfile
      gemfile = File.read(gemfile)
      gems  = gemfile.scan(/gem\s['"]+([^'"]+)['"]/).flatten
      ruby  = gemfile.scan(/ruby\s['"]+([0-9.]+)['"]/).flatten[0]

      framework = gems.include?("rails") ? "Rails" : "Sinatra"
      ruby_version = ruby || "2.2.0"

      puts "-----> Ruby/#{framework} app detected"
      puts "-----> Using Ruby version: #{ruby_version}"
      puts "-----> Creating Dockerfile"

      template  = File.read(self.template_dir.join("ruby", "Dockerfile.erb"))
      namespace = OpenStruct.new(
        "ruby_version"      => ruby_version,
        "ruby_abi_version"  => "2.2.0",
        "bundler_version"   => "1.6.3",
        "framework"         => framework
      )
      erb = ERB.new(template).result(namespace.instance_eval { binding })
      erb.gsub!(/\n\n+/, "\n\n") # beautify ERB output
      File.write(path.join("Dockerfile"), erb)

      puts "-----> Creating fig.yml"
      fig = {}

      procfile = path.join("Procfile")
      process_types = Hash[File.read(procfile).split("\n").map do |line|
        if line =~ /^([A-Za-z0-9_]+):\s*(.+)$/
          [$1, $2]
        end
      end.compact]

      puts "-----> Discovering process types: #{process_types.keys.join(', ')}"

      if gems.include?("pg")
        puts "-----> Discovering add-on services: Postgres"
        fig["postgres"] = {
          "image" => "postgres:latest",
          "ports" => [5432],
        }
      end

      process_types.each do |name, cmd|
        fig[name] = {
          "build"       => ".",
          "command"     => cmd,
          "volumes"     => [".:myapp"],
          "environment" => []
        }

        if name == "web"
          fig[name]["ports"] = ["5000:5000"]

          env = path.join(".env")
          if File.exists?(env)
            File.read(env).split("\n").each do |line|
              fig[name]["environment"] << line
            end

            puts "-----> Discovering .env"
          end
        end

        if name == "test"
          env = path.join(".env.test")
          if File.exists?(env)
            File.read(env).split("\n").each do |line|
              fig[name]["environment"] << line
            end

            puts "-----> Discovering .env.test"
          end
        end

        if gems.include?("pg")
          project = path.basename.to_s.gsub(/[^a-zA-Z0-9]/, "")
          fig[name]["links"] = ["postgres"]
          fig[name]["environment"] << "DATABASE_URL=postgres://postgres@postgres/#{project}-#{name}"
        end
      end

      File.write(path.join("fig.yml"), YAML.dump(fig))
    end
  end

  def self.build(path)
    abort "error: fig.yml does not exist"  unless File.exists? path.join("fig.yml")

    Dir.chdir(path) do
      system "fig build"
    end
  end

  def self.test(path)
    abort "error: fig.yml does not exist"  unless File.exists? path.join("fig.yml")

    Dir.chdir(path) do
      system "fig run test"
    end
  end

  def self.release(path, app)
    Dir.chdir(path) do
      project = path.basename.to_s.gsub(/[^a-zA-Z0-9]/, "")

      token = ENV["HEROKU_AUTH_TOKEN"] || `heroku auth:token`.strip
      abort "error: heroku auth token does not exist" unless token

      # assume `build` happened and the container is known
      # TODO: do this in net/https instead of docker / excon gems?
      containers = Docker::Util.parse_json Docker.connection.get("/containers/json", { all: true })
      container  = containers.detect { |c| c["Image"].start_with? project.to_s }
      image      = Docker::Util.parse_json Docker.connection.get("/images/#{container['Image']}/json")
      history    = Docker::Util.parse_json Docker.connection.get("/images/#{container['Image']}/history")

      # extract process_types from Procfile
      process_types = File.read(path.join("Procfile")).split("\n").map do |line|
        if line =~ /^([A-Za-z0-9_]+):\s*(.+)$/
          [$1, $2]
        end
      end.compact

      puts "PUT slug and process_types from Procfile to Heroku"

      uri = URI.parse("https://api.heroku.com/apps/#{app}/slugs")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      request = Net::HTTP::Post.new(uri.request_uri)
      request.add_field("Content-Type",   "application/json")
      request.add_field("Accept",         "application/vnd.heroku+json; version=3")
      request.add_field("Authorization",  "Bearer #{token}")
      request.body = { process_types: Hash[process_types] }.to_json
      response = http.request(request)
      abort "error: #{response.body}" unless response.code == "201"

      slug_json = JSON.parse(response.body)
      put_url = slug_json["blob"]["url"]

      puts "Extract slug archive from container"

      pid = `docker run -d #{image['Id']} tar cfz /tmp/slug.tgz -C / --exclude=.git ./app`.strip
      system "docker logs -f #{pid}" # wait on the command to exist
      system "docker cp #{pid}:/tmp/slug.tgz /tmp"

      puts "PUT slug archive to S3"

      # TODO: https://github.com/rlmcpherson/s3gof3r ?
      system "curl -X PUT -H 'Content-Type:' --data-binary @/tmp/slug.tgz '#{put_url}'"
      abort "error: PUT failed" unless $? == 0

      puts "PUT release to Heroku"

      uri = URI.parse("https://api.heroku.com/apps/#{app}/releases")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      request = Net::HTTP::Post.new(uri.request_uri)
      request.add_field("Content-Type",   "application/json")
      request.add_field("Accept",         "application/vnd.heroku+json; version=3")
      request.add_field("Authorization",  "Bearer #{token}")
      request.body = { slug: slug_json["id"] }.to_json
      response = http.request(request)
      abort "error: #{response.body}" unless response.code == "201"

      puts "Extract ENV from image and PATCH config vars on Heroku"

      envs = Hash[history.map { |h| h["CreatedBy"].scan(/sh .* ENV\s+([^=]+)=([^ ]+)/)[0] }.compact]

      uri = URI.parse("https://api.heroku.com/apps/#{app}/config-vars")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      request = Net::HTTP::Patch.new(uri.request_uri)
      request.add_field("Content-Type",   "application/json")
      request.add_field("Accept",         "application/vnd.heroku+json; version=3")
      request.add_field("Authorization",  "Bearer #{token}")
      request.body = envs.to_json
      response = http.request(request)
      abort "error: #{response.body}" unless response.code == "200"

      puts "Detect Postgres and/or Redis from fig.yml and GET and POST on Heroku"

      uri = URI.parse("https://api.heroku.com/apps/#{app}/addons")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      request = Net::HTTP::Get.new(uri.request_uri, { "accept-encoding" => "UTF-8" })
      request.add_field("Accept",         "application/vnd.heroku+json; version=3")
      request.add_field("Authorization",  "Bearer #{token}")
      response = http.request(request)
      abort "error: #{response.body}" unless response.code == "200"

      addons = JSON.parse(response.body)

      fig_yml = YAML.load_file path.join("fig.yml")

      if fig_yml["postgres"]
        if addons.detect { |a| a["name"] =~ /heroku-postgresql/ }
          puts "GET addons heroku-postgresql already exists"
        else
          uri = URI.parse("https://api.heroku.com/apps/#{app}/addons")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          request = Net::HTTP::Post.new(uri.request_uri)
          request.add_field("Content-Type",   "application/json")
          request.add_field("Accept",         "application/vnd.heroku+json; version=3")
          request.add_field("Authorization",  "Bearer #{token}")
          request.body = { plan: "heroku-postgresql:dev" }.to_json
          response = http.request(request)
          abort "error: #{response.body}" unless response.code == "201"
          puts "POST addons heroku-postgresql:dev"
        end
      end

      if fig_yml["redis"]
        if addons.detect { |a| a["name"] =~ /heroku-redis/ }
          puts "GET addons heroku-redis:standard-4 already exists"
        else
          uri = URI.parse("https://api.heroku.com/apps/#{app}/addons")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          request = Net::HTTP::Post.new(uri.request_uri)
          request.add_field("Content-Type",   "application/json")
          request.add_field("Accept",         "application/vnd.heroku+json; version=3")
          request.add_field("Authorization",  "Bearer #{token}")
          request.body = { plan: "heroku-redis:standard-4" }.to_json
          response = http.request(request)
          abort "error: #{response.body}" unless response.code == "201"
          puts "POST addons heroku-redis:standard-4"
        end
      end
    end
  end
end
