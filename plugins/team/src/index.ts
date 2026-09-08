//
// Copyright 2025
//

import { type Doc, type Ref, type Class } from "@hcengineering/core"
import type { Asset, IntlString, Plugin } from "@hcengineering/platform"
import { plugin } from "@hcengineering/platform"
import { type AnyComponent } from "@hcengineering/ui"

export interface Team extends Doc {
  name: string
  description: string
  members: AccountUuid[]
  archived: boolean
}

export const teamId = "team" as Plugin

const teamPlugin = plugin(teamId, {
  class: { Team: "" as Ref<Class<Team>> },
  icon: { Team: "" as Asset },
  component: { TeamManagement: "" as AnyComponent, TeamLabel: "" as AnyComponent },
  string: {
    Team: "" as IntlString, Teams: "" as IntlString, CreateTeam: "" as IntlString,
    EditTeam: "" as IntlString, DeleteTeam: "" as IntlString, TeamName: "" as IntlString,
    TeamDescription: "" as IntlString, TeamMembers: "" as IntlString,
    AddMember: "" as IntlString, RemoveMember: "" as IntlString,
    ArchiveTeam: "" as IntlString, Archived: "" as IntlString,
    NoTeams: "" as IntlString, TeamNamePlaceholder: "" as IntlString,
    TeamDescriptionPlaceholder: "" as IntlString, DefaultTeam: "" as IntlString,
    EffectiveMembers: "" as IntlString
  }
})
export default teamPlugin
