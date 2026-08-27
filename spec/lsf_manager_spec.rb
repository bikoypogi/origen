require 'spec_helper'

describe Origen::Application::LSFManager do
  # Instantiate a real manager; the .lsf/remote_logs dir is created if absent.
  subject(:manager) { described_class.new }

  # ── job-queue helpers ────────────────────────────────────────────────────────
  def set_running(jobs)
    manager.instance_variable_set(:@running_jobs, jobs)
  end

  def set_queuing(jobs)
    manager.instance_variable_set(:@queuing_jobs, jobs)
  end

  # Build a minimal LSF double whose config.detail_threshold is controllable.
  def lsf_double(threshold: 0)
    cfg = instance_double(Origen::Application::LSF::Configuration,
                          detail_threshold: threshold)
    instance_double(Origen::Application::LSF, config: cfg)
  end

  # ============================================================================
  # Origen::Application::LSF::Configuration#detail_threshold
  # ============================================================================
  describe Origen::Application::LSF::Configuration do
    describe '#detail_threshold' do
      it 'defaults to 0 so the feature is off out of the box' do
        expect(described_class.new.detail_threshold).to eq(0)
      end

      it 'can be set to a positive integer' do
        cfg = described_class.new
        cfg.detail_threshold = 10
        expect(cfg.detail_threshold).to eq(10)
      end

      it 'accepts 0 explicitly to disable the feature' do
        cfg = described_class.new
        cfg.detail_threshold = 10
        cfg.detail_threshold = 0
        expect(cfg.detail_threshold).to eq(0)
      end
    end
  end

  # ============================================================================
  # LSFManager#lsf_exec_hosts  (private)
  # ============================================================================
  describe '#lsf_exec_hosts' do
    # Standard bjobs header line
    let(:header) do
      "JOBID  USER  STAT  QUEUE  FROM_HOST  EXEC_HOST           JOB_NAME\n"
    end

    it 'returns {} and logs a debug message when the shell command raises' do
      allow(manager).to receive(:`).and_raise(RuntimeError, 'bjobs: command not found')
      expect(Origen.log).to receive(:debug).with(/lsf_exec_hosts.*bjobs: command not found/i)
      expect(manager.send(:lsf_exec_hosts, ['12345'])).to eq({})
    end

    it 'returns {} when output contains only the JOBID header' do
      allow(manager).to receive(:`).and_return(header)
      expect(manager.send(:lsf_exec_hosts, ['9999'])).to eq({})
    end

    it 'skips lines that begin with "Job" (bjobs error messages)' do
      allow(manager).to receive(:`).and_return("Job <9999> is not found\n")
      expect(manager.send(:lsf_exec_hosts, ['9999'])).to eq({})
    end

    it 'skips lines that begin with "JOBID" (case-insensitive header guard)' do
      line = "JOBID  USER  STAT  QUEUE  FROM_HOST  EXEC_HOST  JOB_NAME\n"
      allow(manager).to receive(:`).and_return(line)
      expect(manager.send(:lsf_exec_hosts, ['12345'])).to eq({})
    end

    it 'skips lines with fewer than 6 fields' do
      allow(manager).to receive(:`).and_return("12345  me  RUN  q  host\n")
      expect(manager.send(:lsf_exec_hosts, ['12345'])).to eq({})
    end

    it 'extracts the hostname shortname (part before the first dot)' do
      output = header + "12345  me  RUN  normal  h0  worker01.cluster.internal  job\n"
      allow(manager).to receive(:`).and_return(output)
      expect(manager.send(:lsf_exec_hosts, ['12345'])).to eq('12345' => 'worker01')
    end

    it 'returns the full exec_host when there is no dot' do
      output = header + "12345  me  RUN  normal  h0  plainhost  job\n"
      allow(manager).to receive(:`).and_return(output)
      expect(manager.send(:lsf_exec_hosts, ['12345'])).to eq('12345' => 'plainhost')
    end

    it 'maps multiple job IDs in a single call' do
      output = header +
               "11111  me  RUN  q  h0  node01.x.com  j1\n" \
               "22222  me  RUN  q  h0  node02.x.com  j2\n"
      allow(manager).to receive(:`).and_return(output)
      result = manager.send(:lsf_exec_hosts, %w[11111 22222])
      expect(result).to eq('11111' => 'node01', '22222' => 'node02')
    end

    it 'ignores lines that have fewer than 6 fields but are not header/error lines' do
      output = header + "only four fields here\n" \
                      + "99999  me  RUN  q  h0  realhost.x  job\n"
      allow(manager).to receive(:`).and_return(output)
      result = manager.send(:lsf_exec_hosts, ['99999'])
      expect(result).to eq('99999' => 'realhost')
    end
  end

  # ============================================================================
  # LSFManager#print_status — new detail-table block
  # ============================================================================
  describe '#print_status detail table' do
    let(:log_lines) { [] }

    before do
      allow(Origen.log).to receive(:info)  { |msg| log_lines << msg.to_s }
      allow(Origen.log).to receive(:debug)
      ENV.delete('ORIGEN_LSF_DETAIL_THRESHOLD')
    end

    after { ENV.delete('ORIGEN_LSF_DETAIL_THRESHOLD') }

    # Suppress instruction block so tests focus on the new detail section only.
    def run_status(threshold:)
      allow(manager).to receive(:lsf).and_return(lsf_double(threshold: threshold))
      manager.print_status(print_insructions: false)
    end

    def detail_logged?
      log_lines.any? { |l| l.include?('LSF Running Job Details') }
    end

    # ── threshold == 0 (feature disabled) ─────────────────────────────────────
    context 'when detail_threshold is 0 (default)' do
      it 'never emits the detail table regardless of running jobs' do
        set_running([{ lsf_id: '1', command: 'test', switches: '', submitted_at: Time.now }])
        set_queuing([])
        run_status(threshold: 0)
        expect(detail_logged?).to be false
      end
    end

    # ── running_jobs.size >= threshold ────────────────────────────────────────
    context 'when running_jobs count meets or exceeds threshold' do
      it 'does not emit the detail table' do
        jobs = (1..5).map { |i| { lsf_id: i.to_s, command: 'x', switches: '', submitted_at: Time.now } }
        set_running(jobs)
        set_queuing([])
        run_status(threshold: 5)
        expect(detail_logged?).to be false
      end
    end

    # ── queuing jobs still present ────────────────────────────────────────────
    context 'when queuing_jobs is non-empty' do
      it 'does not emit the detail table' do
        set_running([{ lsf_id: '1', command: 'x', switches: '', submitted_at: Time.now }])
        set_queuing([{ lsf_id: '2', command: 'y', switches: '' }])
        run_status(threshold: 5)
        expect(detail_logged?).to be false
      end
    end

    # ── no running jobs ───────────────────────────────────────────────────────
    context 'when running_jobs is empty' do
      it 'does not emit the detail table' do
        set_running([])
        set_queuing([])
        run_status(threshold: 5)
        expect(detail_logged?).to be false
      end
    end

    # ── happy-path: detail table is shown ─────────────────────────────────────
    context 'when threshold > 0, running < threshold, and queuing == 0' do
      let(:job) do
        { lsf_id: '99001', command: 'origen compile', switches: ' --exec_remote',
          submitted_at: Time.now - 90 }
      end

      before do
        set_running([job])
        set_queuing([])
        allow(manager).to receive(:lsf_exec_hosts).and_return('99001' => 'worker01')
      end

      it 'prints the LSF Running Job Details header' do
        run_status(threshold: 5)
        expect(detail_logged?).to be true
      end

      it 'includes the threshold and job count in the header line' do
        run_status(threshold: 5)
        expect(log_lines.join("\n")).to match(/1 job.*threshold 5/i)
      end

      it 'includes the LSF job ID in the output' do
        run_status(threshold: 5)
        expect(log_lines.any? { |l| l.include?('99001') }).to be true
      end

      it 'shows the resolved exec host from lsf_exec_hosts' do
        run_status(threshold: 5)
        expect(log_lines.any? { |l| l.include?('worker01') }).to be true
      end

      it 'strips --exec_remote from the displayed command' do
        run_status(threshold: 5)
        expect(log_lines.join("\n")).not_to include('--exec_remote')
      end

      it 'shows a human-readable elapsed duration for submitted_at' do
        run_status(threshold: 5)
        expect(log_lines.join("\n")).to match(/\d+ (second|minute|hour|day)/)
      end

      it 'falls back to "-" for exec_host when bjobs returns no data for that ID' do
        allow(manager).to receive(:lsf_exec_hosts).and_return({})
        run_status(threshold: 5)
        # The host column for job 99001 should be "-"
        detail_lines = log_lines.select { |l| l.include?('99001') }
        expect(detail_lines.first).to include('-')
      end

      it 'calls lsf_exec_hosts with only the valid job IDs' do
        expect(manager).to receive(:lsf_exec_hosts).with(['99001']).and_return({})
        run_status(threshold: 5)
      end
    end

    # ── submitted_at is nil ───────────────────────────────────────────────────
    context 'when a job has no submitted_at time' do
      before do
        set_running([{ lsf_id: '88', command: 'x', switches: '', submitted_at: nil }])
        set_queuing([])
        allow(manager).to receive(:lsf_exec_hosts).and_return({})
      end

      it 'shows "(unknown)" for the elapsed duration' do
        run_status(threshold: 5)
        expect(log_lines.join("\n")).to include('(unknown)')
      end
    end

    # ── filtering invalid lsf_ids ─────────────────────────────────────────────
    context 'when all running jobs have nil lsf_id' do
      before do
        set_running([{ lsf_id: nil, command: 'x', switches: '', submitted_at: Time.now }])
        set_queuing([])
      end

      it 'does not emit the detail table (valid_jobs is empty)' do
        run_status(threshold: 5)
        expect(detail_logged?).to be false
      end
    end

    context 'when all running jobs have :error lsf_id' do
      before do
        set_running([{ lsf_id: :error, command: 'x', switches: '', submitted_at: Time.now }])
        set_queuing([])
      end

      it 'does not emit the detail table (valid_jobs is empty)' do
        run_status(threshold: 5)
        expect(detail_logged?).to be false
      end
    end

    context 'when a mix of valid and invalid lsf_ids are present' do
      before do
        jobs = [
          { lsf_id: nil,    command: 'bad',  switches: '', submitted_at: Time.now },
          { lsf_id: :error, command: 'bad2', switches: '', submitted_at: Time.now },
          { lsf_id: '777',  command: 'good', switches: '', submitted_at: Time.now }
        ]
        set_running(jobs)
        set_queuing([])
        allow(manager).to receive(:lsf_exec_hosts).and_return('777' => 'host1')
      end

      it 'only displays the job with a valid lsf_id' do
        run_status(threshold: 5)
        expect(log_lines.any? { |l| l.include?('777') }).to be true
      end

      it 'reports the correct count of 1 valid job in the header' do
        run_status(threshold: 5)
        expect(log_lines.join("\n")).to match(/1 job/i)
      end
    end

    # ── ENV var overrides config ───────────────────────────────────────────────
    context 'ENV[ORIGEN_LSF_DETAIL_THRESHOLD] takes precedence over config' do
      before do
        set_running([{ lsf_id: '42', command: 'x', switches: '', submitted_at: Time.now }])
        set_queuing([])
        allow(manager).to receive(:lsf_exec_hosts).and_return({})
      end

      it 'enables the table when ENV is positive and config is 0' do
        ENV['ORIGEN_LSF_DETAIL_THRESHOLD'] = '5'
        allow(manager).to receive(:lsf).and_return(lsf_double(threshold: 0))
        manager.print_status(print_insructions: false)
        expect(detail_logged?).to be true
      end

      it 'disables the table when ENV is "0" even if config threshold is > 0' do
        ENV['ORIGEN_LSF_DETAIL_THRESHOLD'] = '0'
        allow(manager).to receive(:lsf).and_return(lsf_double(threshold: 10))
        manager.print_status(print_insructions: false)
        expect(detail_logged?).to be false
      end

      it 'uses the ENV numeric value as the threshold' do
        ENV['ORIGEN_LSF_DETAIL_THRESHOLD'] = '2'
        # 1 running job < threshold of 2  → should show
        allow(manager).to receive(:lsf).and_return(lsf_double(threshold: 0))
        manager.print_status(print_insructions: false)
        expect(detail_logged?).to be true
      end
    end
  end
end
