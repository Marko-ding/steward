# SPDX-License-Identifier: Apache-2.0

Mox.defmock(Steward.MockController, for: Steward.Controller)
Mox.defmock(Steward.MockWorker, for: [Steward.Worker, Oban.Worker])
