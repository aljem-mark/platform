import { type Resources } from "@hcengineering/platform"
import GroupManagement from "./components/GroupManagement.svelte"
import GroupLabel from "./components/GroupLabel.svelte"
import CreateGroup from "./components/CreateGroup.svelte"

export default async (): Promise<Resources> => ({
  component: { GroupManagement, GroupLabel, CreateGroup }
})
