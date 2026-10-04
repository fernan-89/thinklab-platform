#!/bin/sh
# Runs inside the anchor-store (LocalStack) container once it is ready: creates the anchor bucket WITH Object Lock, which can only be
# chosen when the bucket is created (ledger ADR-035). Idempotent.
awslocal s3api create-bucket --bucket thinklab-anchors --object-lock-enabled-for-bucket >/dev/null 2>&1 || awslocal s3api head-bucket --bucket thinklab-anchors
