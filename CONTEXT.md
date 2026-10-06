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
