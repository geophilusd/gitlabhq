# frozen_string_literal: true

require "fog/google"

module QA
  module Support
    class KnapsackReport
      PROJECT = "gitlab-qa-resources"
      BUCKET = "knapsack-reports"
      FALLBACK_REPORT = "knapsack/master_report.json"
      PATTERN_VAR_NAME = "KNAPSACK_TEST_FILE_PATTERN"
      DEFAULT_TEST_PATTERN = "qa/specs/features/**/*_spec.rb"
      EXAMPLE_RUNTIMES_PATH = "example_runtimes"

      class << self
        delegate :configure!,
          :move_regenerated_report,
          :download_report,
          :upload_report,
          :upload_example_runtimes,
          :merged_report,
          to: :new
      end

      def initialize(report_name = nil)
        @report_name = report_name
      end

      # Configure knapsack report
      #
      # * Setup variables
      # * Fetch latest report
      #
      # @return [void]
      def configure!
        return unless QA::Runtime::Env.knapsack?

        setup_logger!
        setup_environment!
        download_report
      end

      # Download knapsack report from gcs bucket
      #
      # @return [void]
      def download_report
        logger.info("Downloading latest knapsack report for '#{report_name}' to '#{report_path}'")
        return logger.info("Report already exists, skipping!") if File.exist?(report_path)

        file = client.get_object(BUCKET, report_file)
        File.write(report_path, file[:body])
      rescue StandardError => e
        ENV["KNAPSACK_REPORT_PATH"] = FALLBACK_REPORT
        logger.warn("Failed to fetch latest knapsack report: #{e}")
        logger.warn("Falling back to '#{FALLBACK_REPORT}'")
      end

      # Create a copy of the report that contains the selective tests and has '-selective' suffix
      #
      # @param [String] qa_tests
      # @return [void]
      def create_for_selective(qa_tests)
        timed_specs = JSON.parse(File.read(report_path))

        qa_tests_array = qa_tests.split(' ')
        filtered_timed_specs = timed_specs.select { |k, _| qa_tests_array.any? { |qa_test| k.include? qa_test } }
        File.write(selective_path, filtered_timed_specs.to_json)
      end

      # Rename and move new regenerated report to a separate folder used to indicate report name
      #
      # @return [void]
      def move_regenerated_report
        return unless ENV["KNAPSACK_GENERATE_REPORT"] == "true"

        tmp_path = "tmp/knapsack/#{report_name}"
        FileUtils.mkdir_p(tmp_path)

        # Use path from knapsack config in case of fallback to master_report.json
        knapsack_report_path = Knapsack.report.report_path
        logger.debug("Moving regenerated #{knapsack_report_path} to save as artifact")
        FileUtils.cp(knapsack_report_path, "#{tmp_path}/#{ENV['CI_NODE_INDEX']}.json")
      end

      # Merge and upload knapsack report to gcs bucket
      #
      # Fetches all files defined in glob and uses parent folder as report name
      #
      # @param [String] glob
      # @return [void]
      def upload_report(glob)
        reports = Pathname.glob(glob).each_with_object(Hash.new { |hsh, key| hsh[key] = [] }) do |report, hash|
          next unless report.extname == ".json"

          hash[report.parent.basename.to_s].push(report)
        end
        return logger.error("Glob '#{glob}' did not contain any valid report files!") if reports.empty?

        reports.each do |name, jsons|
          file = "#{name}.json"

          report = jsons
            .map { |json| JSON.parse(File.read(json)) }
            .reduce({}, :merge)
            .sort_by { |_k, v| v } # sort report by execution time
            .to_h
          next logger.warn("Knapsack generated empty report for '#{name}', skipping upload!") if report.empty?

          logger.info("Uploading latest knapsack report '#{file}'")
          client.put_object(BUCKET, file, JSON.pretty_generate(report))
        rescue StandardError => e
          logger.error("Failed to upload knapsack report for '#{name}'. Error: #{e}")
        end
      end

      # Create and upload custom report based on data from JsonFormatter report files
      #
      # @param glob [String]
      # @return [void]
      def upload_example_runtimes(glob)
        raise "QA_RUN_TYPE must be set for custom report" unless run_type

        reports = Pathname.glob(glob).select { |file| file.extname == ".json" }
        raise "Glob '#{glob}' did not contain any valid report files!" if reports.empty?

        logger.info("Processing '#{reports.size}' report files")
        report = example_runtimes(reports).sort.to_h

        file = "#{EXAMPLE_RUNTIMES_PATH}/#{run_type}.json"
        logger.info("Uploading example runtime report '#{file}'")
        client.put_object(BUCKET, file, JSON.pretty_generate(report))
      end

      # Merged example runtime data from all report files
      #
      # @return [Hash<String, Number>]
      def merged_runtime_data
        return @merged_runtime_data if @merged_runtime_data

        logger.info("Fetching all example runtime data from GCS '#{BUCKET}' bucket")
        items = client.list_objects(BUCKET, prefix: EXAMPLE_RUNTIMES_PATH).items
        logger.info("Fetched example runtime files #{items.map(&:name)}, creating merged knapsack report")
        @merged_runtime_data = client.list_objects(BUCKET, prefix: EXAMPLE_RUNTIMES_PATH).items
          .each_with_object({}) do |report, runtimes|
            json = JSON.parse(client.get_object(BUCKET, report.name)[:body])

            # merge report and keep only the longest runtime
            json.each { |id, runtime| runtimes[id] = runtime unless (runtimes[id] || 0) > runtime }
          end
      end

      # Create merged knapsack report from example runtimes reports
      #
      # @return [Hash<String, Number>]
      def merged_report
        merged_runtime_data.each_with_object(Hash.new { |hsh, key| hsh[key] = 0 }) do |(id, runtime), spec_runtimes|
          file_path = id.match(/(\S+)\[\S+\]/)[1].gsub("./", "")

          spec_runtimes[file_path] += runtime
        end
      end

      private

      delegate :run_type, to: QA::Runtime::Env

      # Setup knapsack logger
      #
      # @return [void]
      def setup_logger!
        Knapsack.logger = logger
      end

      # Set knapsack environment variables
      #
      # @return [void]
      def setup_environment!
        ENV["KNAPSACK_TEST_DIR"] = "qa/specs"
        ENV["KNAPSACK_REPORT_PATH"] = report_path
        ENV[PATTERN_VAR_NAME] = ENV[PATTERN_VAR_NAME].presence || DEFAULT_TEST_PATTERN
      end

      # Logger instance
      #
      # @return [ActiveSupport::Logger]
      def logger
        QA::Runtime::Logger.logger
      end

      # GCS client
      #
      # @return [Fog::Storage::GoogleJSON]
      def client
        @client ||= Fog::Storage::Google.new(google_project: PROJECT, **gcs_credentials)
      end

      # Base path of knapsack report
      #
      # @return [String]
      def report_base_path
        @report_base_path ||= "knapsack"
      end

      # Knapsack report path
      #
      # @return [String]
      def report_path
        @report_path ||= "#{report_base_path}/#{report_file}"
      end

      # Knapsack report name
      #
      # @return [String]
      def report_file
        @report_file ||= "#{report_name}.json"
      end

      # Report name
      #
      # Infer report name from ci job name
      # Remove characters incompatible with gcs bucket naming from job names like ee:instance-parallel
      #
      # @return [String]
      def report_name
        @report_name ||= ENV["QA_KNAPSACK_REPORT_NAME"] || ENV["CI_JOB_NAME"].split(" ").first.tr(":", "-")
      end

      # GCS credentials json
      #
      # @return [Hash]
      def gcs_credentials
        json_key = ENV["QA_KNAPSACK_REPORT_GCS_CREDENTIALS"] || raise(
          "QA_KNAPSACK_REPORT_GCS_CREDENTIALS env variable is required!"
        )
        return { google_json_key_location: json_key } if File.exist?(json_key)

        { google_json_key_string: json_key }
      end

      # Add '-selective-parallel' suffix to report name
      #
      # @return [String]
      def selective_path
        extension = File.extname(report_path)
        directory = File.dirname(report_path)
        file_name = File.basename(report_path, extension)

        File.join(directory, "#{file_name}-selective-parallel#{extension}")
      end

      # Get example runtimes from JsonFormatter report files
      #
      # @param reports [Array<Pathname>]
      # @return [Hash<Number>]
      def example_runtimes(reports)
        reports
          .flat_map { |report| JSON.load_file(report, symbolize_names: true) }
          .each_with_object({}) do |json, runtimes|
            json[:examples].each do |ex|
              next if ex[:ignore_runtime_data] || ex[:status] != "passed"

              # keep the longest running example
              runtimes[ex[:id]] = ex[:run_time] unless (runtimes[:id] || 0) > ex[:run_time]
            end
          end
      end
    end
  end
end
