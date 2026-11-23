require 'open3'
require 'tempfile'

module ProvisionCompatibilityPatch
  REVISION = '4b444d86b533dfc887266a51a9f089b4bae8ea7d'

  def self.replace_once(source, old_text, new_text, description, already_patched: nil)
    return source if already_patched && source.include?(already_patched)

    count = source.scan(Regexp.new(Regexp.escape(old_text))).length
    if count.zero?
      raise "Expected one #{description} match, found none"
    end
    raise "Expected one #{description} match, found #{count}" unless count == 1

    source.sub(old_text, new_text)
  end

  def self.replace_line(source, pattern, description, already_patched:)
    matches = source.to_enum(:scan, pattern).map { Regexp.last_match }
    if matches.empty?
      return source if source.include?(already_patched)

      raise "Expected one #{description} match, found none"
    end
    raise "Expected one #{description} match, found #{matches.length}" unless matches.length == 1

    match = matches.first
    indent = match[1]
    source.sub(pattern) { yield(indent) }
  end

  def self.replace_method(source, name, replacement, description, already_patched:)
    return source if source.include?(already_patched)

    pattern = /^  def #{Regexp.escape(name)}\b.*?^  end$/m
    matches = source.to_enum(:scan, pattern).map { Regexp.last_match }
    raise "Expected one #{description} match, found #{matches.length}" unless matches.length == 1

    source.sub(pattern) do
      indent_lines(replacement.lines.map(&:chomp), '  ')
    end
  end

  def self.indent_lines(lines, indent)
    lines.map { |line| line.empty? ? '' : "#{indent}#{line}" }.join("\n")
  end

  def self.write_atomically(path, content)
    mode = File.stat(path).mode & 0o777
    temp_file = Tempfile.new('.agentforge-patch', File.dirname(path))
    temp_path = temp_file.path
    temp_file.chmod(mode)
    temp_file.write(content)
    temp_file.flush
    temp_file.fsync
    temp_file.close
    File.rename(temp_path, path)
  ensure
    temp_file.close if temp_file && !temp_file.closed?
    File.delete(temp_path) if temp_path && File.exist?(temp_path)
  end

  def self.update(path)
    source = File.read(path)
    updated = yield(source)
    write_atomically(path, updated) unless updated == source
  end

  def self.patch_task_helper(path)
    update(path) do |source|
      source = replace_line(
        source,
        /^([ \t]*)stdout, stderr, status = Open3\.capture3\(command, chdir: dir\)$/,
        'Vagrant child environment',
        already_patched: 'Open3.capture3(environment, command, chdir: dir)',
      ) do |indent|
        indent_lines(
          [
            'environment = ENV.to_h.reject do |key, _value|',
            "  key.start_with?('BUNDLE_', 'BUNDLER_') ||",
            '    %w[GEM_HOME GEM_PATH RUBYLIB RUBYOPT].include?(key)',
            'end',
            'stdout, stderr, status = Open3.capture3(environment, command, chdir: dir)',
          ],
          indent,
        )
      end
      source
    end
  end

  def self.patch_inventory_helper(path)
    update(path) do |source|
      source = "require 'tempfile'\n#{source}" unless source.include?("require 'tempfile'")
      source = source.sub("require 'tempfile'\n# frozen_string_literal: true\n", "# frozen_string_literal: true\n\nrequire 'tempfile'\n")
      source = replace_line(
        source,
        /^([ \t]*)File\.open\(@location, 'wb\+'\) \{ \|f\| f\.write\(to_yaml\) \}$/,
        'atomic inventory save',
        already_patched: "File.rename(temp_path, @location)",
      ) do |indent|
        indent_lines(
          [
            "temp_file = Tempfile.new('.litmus-inventory', File.dirname(@location))",
            'temp_path = temp_file.path',
            'begin',
            '  temp_file.write(to_yaml)',
            '  temp_file.flush',
            '  temp_file.fsync',
            '  temp_file.close',
            '  File.rename(temp_path, @location)',
            'ensure',
            '  temp_file.close if temp_file && !temp_file.closed?',
            '  File.delete(temp_path) if temp_path && File.exist?(temp_path)',
            'end',
          ],
          indent,
        )
      end
      source = replace_method(
        source,
        'remove',
        <<~'RUBY',
          def remove(node)
            node = JSON.parse(node.to_json)
            identifiers = [node['uri'], node['name']].compact
            self['groups'].each do |g|
              g['targets'].reject! do |target|
                identifiers.include?(target['uri']) || identifiers.include?(target['name'])
              end
            end

            self
          end
        RUBY
        'inventory removal',
        already_patched: "identifiers = [node['uri'], node['name']].compact",
      )
      source = replace_once(
        source,
        '@instances[location] = new(location) unless @instances.key? location',
        "@instances[location] ||= new(location)\n      @instances[location].__setobj__(@instances[location].refresh)",
        'inventory refresh',
        already_patched: '@instances[location].__setobj__(@instances[location].refresh)',
      )
      source = source.gsub(/^ +\n/, "\n")
      source
    end
  end

  def self.patch_vagrant_task(path)
    update(path) do |source|
      source = replace_once(
        source,
        'config.ssh.insert_key = false',
        'config.ssh.insert_key = true',
        'per-run SSH key',
        already_patched: 'config.ssh.insert_key = true',
      )
      source = replace_once(
        source,
        "  { status: 'ok', node_name:, node: }\nend\n",
        <<~'RUBY',
            { status: 'ok', node_name:, node: }
          rescue StandardError => provision_error
            cleanup_error = nil
            begin
              if defined?(@vagrant_env) && @vagrant_env && File.file?(File.join(@vagrant_env, 'Vagrantfile'))
                run_local_command('vagrant destroy -f', @vagrant_env)
              end
            rescue StandardError => error
              cleanup_error = error
            end
            if cleanup_error.nil?
              begin
                if defined?(node) && node && defined?(inventory) && inventory && File.file?(inventory.location)
                  InventoryHelper.new(inventory.location).remove(node).save
                end
                FileUtils.rm_rf(@vagrant_env) if defined?(@vagrant_env) && @vagrant_env
              rescue StandardError => error
                cleanup_error = error
              end
            end
            raise "#{provision_error.message}; cleanup failed for #{@vagrant_env}: #{cleanup_error.message}" if cleanup_error

            raise
          end
        RUBY
        'provision failure reconciliation',
        already_patched: 'cleanup failed for #{@vagrant_env}',
      )
      source = replace_once(
        source,
        "  run_local_command(command, vagrant_env)\n  FileUtils.rm_r(vagrant_env)\n  inventory.remote(node).save",
        "  run_local_command(command, vagrant_env)\n  InventoryHelper.new(inventory.location).remove(node).save\n  FileUtils.rm_rf(vagrant_env)",
        'teardown inventory cleanup',
        already_patched: "InventoryHelper.new(inventory.location).remove(node).save\n  FileUtils.rm_rf(vagrant_env)",
      )
      source = replace_once(
        source,
        "if File.file?(File.join(@vagrant_env, 'Vagrantfile'))",
        "if defined?(@vagrant_env) && @vagrant_env && File.file?(File.join(@vagrant_env, 'Vagrantfile'))",
        'provision failure path guard',
        already_patched: "if defined?(@vagrant_env) && @vagrant_env && File.file?(File.join(@vagrant_env, 'Vagrantfile'))",
      )
      source
    end
  end

  def self.apply(module_path, expected_revision)
    revision, status = Open3.capture2('git', '-C', module_path, 'rev-parse', 'HEAD')
    raise "Unexpected puppetlabs/provision revision: #{revision.strip}" unless status.success? && revision.strip == expected_revision
    raise "Patch only supports puppetlabs/provision #{REVISION}" unless expected_revision == REVISION

    patch_task_helper(File.join(module_path, 'lib', 'task_helper.rb'))
    patch_inventory_helper(File.join(module_path, 'lib', 'inventory_helper.rb'))
    patch_vagrant_task(File.join(module_path, 'tasks', 'vagrant.rb'))
  end
end

if $PROGRAM_NAME == __FILE__
  ProvisionCompatibilityPatch.apply(ARGV.fetch(0), ARGV.fetch(1))
end
