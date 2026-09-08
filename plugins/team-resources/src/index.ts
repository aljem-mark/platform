import { type Resources } from "@hcengineering/platform"
import TeamManagement from "./components/TeamManagement.svelte"
import TeamLabel from "./components/TeamLabel.svelte"

export default async (): Promise<Resources> => ({
  component: { TeamManagement, TeamLabel }
})
