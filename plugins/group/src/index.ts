//
// Copyright 2025
//

import { type Doc, type Ref, type Class, type AccountUuid } from "@hcengineering/core"
import type { Asset, IntlString, Plugin } from "@hcengineering/platform"
import { plugin } from "@hcengineering/platform"
import { type AnyComponent } from "@hcengineering/ui"

export interface Group extends Doc {
  name: string
  description: string
  members: AccountUuid[]
  archived: boolean
}

export const groupId = "group" as Plugin

const groupPlugin = plugin(groupId, {
  class: { Group: "" as Ref<Class<Group>> },
  icon: { Group: "" as Asset },
  component: { GroupManagement: "" as AnyComponent, GroupLabel: "" as AnyComponent, CreateGroup: "" as AnyComponent },
  string: {
    Group: "" as IntlString, Groups: "" as IntlString, CreateGroup: "" as IntlString,
    EditGroup: "" as IntlString, DeleteGroup: "" as IntlString, GroupName: "" as IntlString,
    GroupDescription: "" as IntlString, GroupMembers: "" as IntlString,
    AddMember: "" as IntlString, RemoveMember: "" as IntlString,
    ArchiveGroup: "" as IntlString, Archived: "" as IntlString,
    NoGroups: "" as IntlString, GroupNamePlaceholder: "" as IntlString,
    GroupDescriptionPlaceholder: "" as IntlString, DefaultGroup: "" as IntlString,
    EffectiveMembers: "" as IntlString,
    GroupCreated: "" as IntlString,
    GroupDeleted: "" as IntlString,
    GroupSaveError: "" as IntlString,
    GroupDeleteError: "" as IntlString,
    DeleteGroupConfirm: "" as IntlString
  }
})
export default groupPlugin
