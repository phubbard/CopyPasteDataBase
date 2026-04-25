using Xunit;

// All tests in this assembly touch the system clipboard (capture, listener,
// or write helper). Running them in parallel would produce nondeterministic
// failures from cross-test interference, so disable parallelization here
// rather than scattering [Collection] attributes everywhere.
[assembly: CollectionBehavior(DisableTestParallelization = true)]
