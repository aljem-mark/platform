//
// Copyright 2025 Hardcore Engineering Inc.
//

import { loadMetadata } from "@hcengineering/platform"
import groupPlugin from "@hcengineering/group"

const icons = require("../assets/icons.svg") as string // eslint-disable-line
loadMetadata(groupPlugin.icon, {
  Group: `${icons}#group`
})
