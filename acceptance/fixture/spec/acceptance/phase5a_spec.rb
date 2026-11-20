require 'spec_helper_acceptance'

describe 'AgentForge Phase 5a fixture' do
  it 'applies a Puppet resource and verifies the result' do
    manifest = <<~PUPPET
      file { '/tmp/agentforge-phase5a-marker':
        ensure  => file,
        content => "AgentForge Phase 5a\\n",
        mode    => '0644',
      }
    PUPPET

    result = apply_manifest(manifest, expect_changes: true)
    expect(result.exit_code).to eq(2)

    assertion = run_shell('cat /tmp/agentforge-phase5a-marker')
    expect(assertion.stdout.chomp).to eq('AgentForge Phase 5a')
  end
end
