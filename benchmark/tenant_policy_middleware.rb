# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "benchmark"
require "digest"
require "sidekiq_tenant_policy_cache"

State = SidekiqTenantPolicyCache::TenantPolicyMiddleware::State
Client = SidekiqTenantPolicyCache::TenantPolicyMiddleware::Client

ITERATIONS = Integer(ENV.fetch("ITERATIONS", 25_000))
STATE = State.new
POLICY = lambda do |tenant:, job_class:, queue:, args:, msg:|
  20.times do |index|
    Digest::SHA256.hexdigest("#{tenant}:#{job_class}:#{queue}:#{index}")
  end

  tenant == "acme" && job_class == "ExportJob" && queue == "default"
end
MIDDLEWARE = Client.new(policy: POLICY, state: STATE)
JOB = {
  "class" => "ExportJob",
  "args" => [{"tenant_id" => "acme"}],
  "queue" => "default",
  "jid" => "jid"
}.freeze

class ExportJob
end

Benchmark.bm(28) do |x|
  x.report("policy lookup every job") do
    ITERATIONS.times do
      POLICY.call(tenant: "acme", job_class: "ExportJob", queue: "default", args: JOB["args"], msg: JOB)
    end
  end

  x.report("ratomic middleware cached") do
    ITERATIONS.times do
      MIDDLEWARE.call(ExportJob, JOB, "default", nil) { true }
    end
  end
end

puts STATE.metrics.snapshot
