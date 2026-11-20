require "securerandom"

module AgentForgeGhAuth
  ROOT = "/tmp/agentforge-gh"
  TOKEN_PATH = "#{ROOT}/pat"
  GH_CONFIG_DIR = "#{ROOT}/config"
  TOKEN_PATTERN = /\Agithub_pat_[A-Za-z0-9_]{8,245}\z/

  class StorageError < StandardError; end

  def self.tmpfs_mounted?
    File.foreach("/proc/mounts").any? do |line|
      fields = line.split
      fields[1] == "/tmp" && fields[2] == "tmpfs"
    end
  rescue SystemCallError
    false
  end

  def self.root_secure?
    return false unless tmpfs_mounted?

    stat = File.lstat(ROOT)
    stat.directory? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o700
  rescue SystemCallError
    false
  end

  def self.validate_root!
    raise StorageError unless root_secure?
  end

  def self.valid_token?(token)
    token.is_a?(String) && TOKEN_PATTERN.match?(token)
  end

  def self.stored_token
    File.open(TOKEN_PATH, File::RDONLY | File::NOFOLLOW) do |file|
      stat = file.stat
      return [:invalid, nil] unless stat.file? \
        && stat.uid == Process.uid \
        && stat.nlink == 1 \
        && (stat.mode & 0o777) == 0o600

      token = file.read(257)
      return [:invalid, nil] unless file.read(1).nil? && valid_token?(token)

      [:stored, token]
    end
  rescue Errno::ENOENT
    [:missing, nil]
  rescue SystemCallError
    [:invalid, nil]
  end

  def self.token_state
    validate_root!
    stored_token.first
  end

  def self.read_token
    validate_root!
    state, token = stored_token
    return nil if state == :missing
    raise StorageError unless state == :stored

    token
  end

  def self.store_token(token)
    validate_root!
    raise StorageError unless valid_token?(token)
    raise StorageError if token_state == :invalid

    temporary_path = File.join(ROOT, ".pat-#{Process.pid}-#{SecureRandom.hex(8)}")
    begin
      File.open(temporary_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(token)
        file.flush
        file.chmod(0o600)
      end
      File.rename(temporary_path, TOKEN_PATH)
    ensure
      File.unlink(temporary_path) if File.exist?(temporary_path)
    end
  rescue SystemCallError
    raise StorageError
  end

  def self.clear_token
    validate_root!
    return false unless File.exist?(TOKEN_PATH) || File.symlink?(TOKEN_PATH)

    stat = File.lstat(TOKEN_PATH)
    raise StorageError if stat.directory?

    File.unlink(TOKEN_PATH)
    true
  rescue SystemCallError
    raise StorageError
  end
end
