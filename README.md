# Sidekiq Tenant Policy Cache

This is focused Sidekiq middleware for caching tenant policy decisions with
`Ratomic::Map` and tracking middleware counters with `Ratomic::Counter`, without
changing Sidekiq job execution semantics for existing users.

The strongest fit is tenant policy state at the middleware boundary:

- `Ratomic::Map` caches immutable allow/deny decisions by tenant, job class, and
  queue. Sidekiq creates a new middleware instance per job, so the cache lives in
  an explicit shared `State` object.
- `Ratomic::Counter` tracks cache hits, misses, allowed jobs, denied jobs,
  completions, errors, retries, and bypasses.

The middleware is opt-in. If no policy is configured, or a job has no tenant, it
bypasses the policy and yields normally.

## Usage

```ruby
require "sidekiq_tenant_policy_cache"

STATE = SidekiqTenantPolicyCache::TenantPolicyMiddleware::State.new
POLICY = lambda do |tenant:, job_class:, queue:, args:, msg:|
  tenant != "suspended"
end

Sidekiq.configure_client do |config|
  config.client_middleware do |chain|
    chain.add SidekiqTenantPolicyCache::TenantPolicyMiddleware::Client,
      policy: POLICY,
      state: STATE
  end
end

Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add SidekiqTenantPolicyCache::TenantPolicyMiddleware::Server,
      policy: POLICY,
      state: STATE
  end
end
```

The middleware looks for `tenant_id` on the job payload first, then in the first
argument when it is hash-like.

## Limits

This middleware intentionally does not persist policy decisions, publish metrics, or
replace Sidekiq's built-in retry, stats, or Redis behavior. Cached policy values
should be small immutable Ruby values such as booleans or symbols.

The benchmark simulates a policy lookup expensive enough to be worth caching. It
is not a claim that middleware caching improves a trivial in-memory predicate.

## Verification

```bash
bundle exec rake
bundle exec ruby benchmark/tenant_policy_middleware.rb
```

## Benchmark Knob

The benchmark uses `ITERATIONS` to control how many jobs it simulates:

```bash
ITERATIONS=100000 bundle exec ruby benchmark/tenant_policy_middleware.rb
```

## Benchmark Snapshot

On this machine, with the current code and `ITERATIONS=25000`, the benchmark
reported:

```text
policy lookup every job        0.871869   0.000000   0.871869 (  0.872057)
ratomic middleware cached      0.053152   0.000000   0.053152 (  0.053168)
{cache_hits: 24999, cache_misses: 1, allowed: 25000, denied: 0, completed: 0, errors: 0, retried: 0, bypassed: 0}
```

That is the point of the middleware: repeated policy decisions for the same
tenant/job/queue combination can be cached once and reused many times.
