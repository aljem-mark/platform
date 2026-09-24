<script lang="ts">
  import { createEventDispatcher } from "svelte"
  import core, { type AccountUuid, type Ref } from "@hcengineering/core"
  import presentation, { getClient, MessageBox } from "@hcengineering/presentation"
  import { translate } from "@hcengineering/platform"
  import {
    Modal,
    ModernEditbox,
    showPopup,
    Button,
    Label,
    addNotification,
    NotificationSeverity,
    themeStore
  } from "@hcengineering/ui"
  import groupPlugin, { type Group } from "@hcengineering/group"
  import { AccountArrayEditor } from "@hcengineering/contact-resources"
  import GroupNotification from "./GroupNotification.svelte"

  export let group: Group | undefined = undefined

  const dispatch = createEventDispatcher()
  const client = getClient()

  let name: string = group?.name ?? ""
  let description: string = group?.description ?? ""
  let members: AccountUuid[] = group?.members ?? []
  let saving = false
  let isEdit = group != null

  $: canSave = name.trim().length > 0 && !saving

  function errorMessage (e: any): string {
    return (e?.message ?? "Unknown error") as string
  }

  async function save (): Promise<void> {
    if (!canSave) return
    saving = true
    try {
      if (isEdit && group != null) {
        await client.update(group, {
          name: name.trim(),
          description: description.trim(),
          members
        })
      } else {
        await client.createDoc(
          groupPlugin.class.Group,
          core.space.Workspace,
          {
            name: name.trim(),
            description: description.trim(),
            members,
            archived: false
          }
        )
      }
      const title = await translate(groupPlugin.string.GroupCreated, {}, $themeStore.language)
      addNotification(title, "", GroupNotification)
      dispatch("close")
    } catch (e) {
      console.error("Failed to save group", e)
      const title = await translate(groupPlugin.string.GroupSaveError, {}, $themeStore.language)
      addNotification(title, errorMessage(e), GroupNotification, undefined, NotificationSeverity.Error)
    } finally {
      saving = false
    }
  }

  function handleMembersChange (newMembers: AccountUuid[]): void {
    members = newMembers
  }

  async function handleDelete (): Promise<void> {
    if (group == null) return
    showPopup(MessageBox, {
      label: groupPlugin.string.DeleteGroup,
      message: groupPlugin.string.DeleteGroupConfirm,
      params: { name: group.name },
      dangerous: true,
      action: async () => {
        try {
          await client.removeDoc(groupPlugin.class.Group, group.space, group._id)
          const title = await translate(groupPlugin.string.GroupDeleted, {}, $themeStore.language)
          addNotification(title, "", GroupNotification)
          dispatch("close")
        } catch (e) {
          console.error("Failed to delete group", e)
          const title = await translate(groupPlugin.string.GroupDeleteError, {}, $themeStore.language)
          addNotification(title, errorMessage(e), GroupNotification, undefined, NotificationSeverity.Error)
        }
      }
    })
  }
</script>

<Modal
  label={isEdit ? groupPlugin.string.EditGroup : groupPlugin.string.CreateGroup}
  type={"type-popup"}
  okLabel={presentation.string.Save}
  okAction={save}
  onCancel={() => dispatch("close")}
  bind:canSave
>
  <div class="flex-col flex-gap-2">
    <ModernEditbox
      bind:value={name}
      label={groupPlugin.string.GroupNamePlaceholder}
      kind={"ghost"}
      size={"large"}
      width={"100%"}
    />
    <ModernEditbox
      bind:value={description}
      label={groupPlugin.string.GroupDescriptionPlaceholder}
      kind={"ghost"}
      size={"small"}
      width={"100%"}
    />
    <div class="members-section">
      <div class="members-caption">
        <Label label={groupPlugin.string.GroupMembers} />
      </div>
      <AccountArrayEditor
        label={groupPlugin.string.GroupMembers}
        value={members}
        onChange={handleMembersChange}
        kind="regular"
        size="large"
        allowGuests={false}
      />
    </div>
  </div>
  <svelte:fragment slot="buttons">
    {#if isEdit}
      <div class="delete-section">
        <Button label={groupPlugin.string.DeleteGroup} kind="dangerous" on:click={handleDelete} />
      </div>
    {/if}
  </svelte:fragment>
</Modal>

<style lang="scss">
  .delete-section {
    margin-right: auto;
  }
  .members-section {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 0.5rem;
    padding-left: var(--spacing-2);
  }
  .members-caption {
    font-weight: 500;
    font-size: 0.875rem;
    color: var(--theme-caption-color);
    line-height: 1.2;
  }
</style>