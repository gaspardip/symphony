# Runtime domain language

A delivery turn is one provider invocation within a durable delivery stage. Its
reported result and captured runtime errors are owned by DeliveryEngine.TurnReport.

A retry budget is the runtime policy for input pressure, accumulated consumption,
turn windows and bounded progress-based extensions. RetryBudget calculates that
policy; RunPolicy applies its persistence and stop effects.

A file focus is the bounded set of paths and compact learning retained for a broad
implement retry. RetryBudget.Focus infers those facts without admitting execution
or renewing a budget window. An explicit expansion path is the single additional
path allowed by the existing broad retry policy.

A physical inbox prefix is one finite capture of ordered physical rows and their
cursors. InboxPrefix preserves its horizon through application and confirmed ACK.
Tracker consumes applied rows before confirmation; GitHub retains its completed
row until confirmation. A confirmed boundary identifies the original remainder,
not a permission to execute effects or consume later appends.
