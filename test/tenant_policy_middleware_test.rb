# frozen_string_literal: true

require_relative "test_helper"
require "sidekiq/middleware/chain"

class TenantPolicyMiddlewareTest < Minitest::Test
  Client = SidekiqTenantPolicyCache::TenantPolicyMiddleware::Client
  Server = SidekiqTenantPolicyCache::TenantPolicyMiddleware::Server
  State = SidekiqTenantPolicyCache::TenantPolicyMiddleware::State

  def setup
    @state = State.new
    @calls = 0
    @policy = lambda do |tenant:, job_class:, queue:, args:, msg:|
      @calls += 1
      tenant != "blocked" && job_class.end_with?("ExportJob") && queue == "default"
    end
  end

  def test_client_allows_and_returns_yield_result
    middleware = Client.new(policy: @policy, state: @state)
    msg = job("tenant_id" => "acme")

    result = middleware.call(ExportJob, msg, "default", nil) { "jid-1" }

    assert_equal "jid-1", result
    assert_equal 1, @calls
    assert_equal({cache_hits: 0, cache_misses: 1, allowed: 1, denied: 0, completed: 0, errors: 0, retried: 0, bypassed: 0}, @state.metrics.snapshot)
  end

  def test_client_reuses_cached_policy_decision
    middleware = Client.new(policy: @policy, state: @state)
    msg = job("tenant_id" => "acme")

    2.times { middleware.call(ExportJob, msg, "default", nil) { true } }

    assert_equal 1, @calls
    assert_equal 1, @state.metrics.cache_hits.to_i
    assert_equal 1, @state.metrics.cache_misses.to_i
    assert_equal 2, @state.metrics.allowed.to_i
  end

  def test_client_works_when_instantiated_by_sidekiq_middleware_chain
    chain = Sidekiq::Middleware::Chain.new
    chain.add Client, policy: @policy, state: @state

    result = chain.invoke(ExportJob, job("tenant_id" => "acme"), "default", nil) { :queued }

    assert_equal :queued, result
    assert_equal 1, @calls
  end

  def test_client_denies_without_yielding
    middleware = Client.new(policy: @policy, state: @state)
    yielded = false

    result = middleware.call(ExportJob, job("tenant_id" => "blocked"), "default", nil) do
      yielded = true
    end

    assert_equal false, result
    refute yielded
    assert_equal 1, @state.metrics.denied.to_i
  end

  def test_server_counts_completion
    middleware = Server.new(policy: @policy, state: @state)
    result = middleware.call(ExportJob.new, job("tenant_id" => "acme"), "default") { :done }

    assert_equal :done, result
    assert_equal 1, @state.metrics.completed.to_i
    assert_equal 0, @state.metrics.errors.to_i
  end

  def test_server_counts_errors_and_retry_attempts_without_swallowing_exception
    middleware = Server.new(policy: @policy, state: @state)
    msg = job("tenant_id" => "acme", "jid" => "abc123", "retry" => true)

    error = assert_raises(RuntimeError) do
      middleware.call(ExportJob.new, msg, "default") { raise "boom" }
    end

    assert_equal "boom", error.message
    assert_equal 1, @state.metrics.errors.to_i
    assert_equal 1, @state.retry_count("abc123")
  end

  def test_missing_tenant_bypasses_policy_and_keeps_sidekiq_behavior
    middleware = Client.new(policy: @policy, state: @state)

    result = middleware.call(ExportJob, job, "default", nil) { :queued }

    assert_equal :queued, result
    assert_equal 0, @calls
    assert_equal 1, @state.metrics.bypassed.to_i
  end

  def test_state_delete_refresh_and_clear_manage_cache
    key_args = {tenant: "acme", job_class: "ExportJob", queue: "default"}

    @state.refresh_policy(**key_args) { true }
    assert_equal true, @state.cache.fetch(@state.cache_key("acme", "ExportJob", "default"), nil)

    assert_equal true, @state.delete_policy(**key_args)
    assert_nil @state.cache.fetch(@state.cache_key("acme", "ExportJob", "default"), nil)

    @state.refresh_policy(**key_args) { false }
    @state.record_retry("jid-1")
    @state.clear!

    assert_equal 0, @state.cache.size
    assert_equal 0, @state.retry_counts.size
  end

  private

  def job(overrides = {})
    {
      "class" => "ExportJob",
      "args" => [],
      "queue" => "default",
      "jid" => "jid"
    }.merge(overrides)
  end

  class ExportJob
  end
end
