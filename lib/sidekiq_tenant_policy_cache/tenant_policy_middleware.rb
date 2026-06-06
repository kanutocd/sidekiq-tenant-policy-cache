# frozen_string_literal: true

require "ratomic"
require "sidekiq/middleware/modules"

module SidekiqTenantPolicyCache
  module TenantPolicyMiddleware
    class Metrics
      COUNTERS = %i[
        cache_hits
        cache_misses
        allowed
        denied
        completed
        errors
        retried
        bypassed
      ].freeze

      COUNTERS.each do |name|
        define_method(name) { counters.fetch(name) }
      end

      def initialize
        @counters = COUNTERS.to_h { |name| [name, Ratomic::Counter.new] }.freeze
      end

      def increment(name, by = 1)
        counters.fetch(name).increment(by)
      end

      def snapshot
        COUNTERS.to_h { |name| [name, counters.fetch(name).to_i] }
      end

      private

      attr_reader :counters
    end

    class State
      attr_reader :cache, :retry_counts, :metrics

      def initialize(cache: Ratomic::Map.new, retry_counts: Ratomic::Map.new, metrics: Metrics.new)
        @cache = cache
        @retry_counts = retry_counts
        @metrics = metrics
      end

      def clear!
        cache.clear
        retry_counts.clear
        self
      end

      def delete_policy(tenant:, job_class:, queue:)
        cache.delete(cache_key(tenant, job_class, queue))
      end

      def refresh_policy(tenant:, job_class:, queue:)
        key = cache_key(tenant, job_class, queue)
        cache.compute(key) { yield }
      end

      def record_retry(jid)
        retry_counts.upsert(jid, 1) { |count| count + 1 }
      end

      def retry_count(jid)
        retry_counts.fetch(jid, 0)
      end

      def cache_key(tenant, job_class, queue)
        [tenant.to_s, job_class_name(job_class), queue.to_s].freeze
      end

      private

      def job_class_name(job_class)
        job_class.respond_to?(:name) ? job_class.name : job_class.to_s
      end
    end

    DEFAULT_STATE = State.new

    class Base
      def initialize(options = nil, **kwargs)
        options = (options || {}).merge(kwargs)
        @policy = options.fetch(:policy, nil)
        @tenant_key = options.fetch(:tenant_key, "tenant_id").to_s
        @state = options.fetch(:state, DEFAULT_STATE)
      end

      private

      attr_reader :policy, :tenant_key, :state

      def check_policy(job_class, msg, queue)
        tenant = tenant_for(msg)
        return :bypassed if policy.nil? || tenant.nil?

        key = state.cache_key(tenant, job_class, queue)
        cached = true
        allowed = state.cache.fetch_or_store(key) do
          cached = false
          allow_job?(tenant, job_class, msg, queue)
        end

        state.metrics.increment(cached ? :cache_hits : :cache_misses)
        state.metrics.increment(allowed ? :allowed : :denied)
        allowed ? :allowed : :denied
      end

      def allow_job?(tenant, job_class, msg, queue)
        !!policy.call(
          tenant: tenant,
          job_class: job_class_name(job_class),
          queue: queue.to_s,
          args: msg.fetch("args", []),
          msg: msg
        )
      end

      def tenant_for(msg)
        explicit = msg[tenant_key]
        return explicit unless explicit.nil? || explicit == ""

        first_arg = msg.fetch("args", []).first
        return unless first_arg.respond_to?(:[])

        first_arg[tenant_key] || first_arg[tenant_key.to_sym]
      end

      def job_class_name(job_class)
        job_class.respond_to?(:name) ? job_class.name : job_class.to_s
      end
    end

    class Client < Base
      include Sidekiq::ClientMiddleware

      def call(job_class, msg, queue, _redis_pool = nil)
        case check_policy(job_class, msg, queue)
        when :denied
          false
        when :bypassed
          state.metrics.increment(:bypassed)
          yield
        else
          yield
        end
      end
    end

    class Server < Base
      include Sidekiq::ServerMiddleware

      def call(worker, msg, queue)
        job_class = msg.fetch("class") { worker.class }

        case check_policy(job_class, msg, queue)
        when :denied
          false
        when :bypassed
          state.metrics.increment(:bypassed)
          yield
        else
          begin
            result = yield
          rescue Exception
            state.metrics.increment(:errors)
            state.record_retry(msg["jid"]) if retrying?(msg)
            raise
          else
            state.metrics.increment(:completed)
            result
          end
        end
      end

      private

      def retrying?(msg)
        msg["retry"] != false && msg["jid"]
      end
    end
  end
end
