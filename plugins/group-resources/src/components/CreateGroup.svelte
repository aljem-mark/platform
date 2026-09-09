<script lang="ts">
  import { createEventDispatcher } from "svelte"
  import core, { type AccountUuid, type Ref } from "@hcengineering/core"
  import presentation, { getClient, MessageBox } from "@hcengineering/presentation"
  import { Modal, ModernEditbox, showPopup, Button } from "@hcengineering/ui"
  import groupPlugin, { type Group } from "@hcengineering/group"
  import { AccountArrayEditor } from "@hcengineering/contact-resources"

  export let group: Group | undefined = undefined

  const dispatch = createEventDispatcher()
  const client = getClient()

  let name: string = group?.name ?? ""
  let description: string = group?.description ?? ""
  let members: AccountUuid[] = group?.members ?? []
  let saving = false
  let isEdit = group != null

  $: canSave = name.trim().length > 0 && !saving

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
            members: [] as AccountUuid[],
            archived: false
          }
        )
      }
    } catch (e) {
      console.error("Failed to save group", e)
    } finally {
      saving = false
      dispatch("close")
    }
  }

  function handleMembersChange (newMembers: AccountUuid[]): void {
    members = newMembers
  }

  async function handleDelete (): Promise<void> {
    if (group == null) return
    showPopup(MessageBox, {
      label: groupPlugin.string.DeleteGroup,
      message: "Delete " + group.name + "?",
      dangerous: true,
      action: async () => {
        await client.removeDoc(groupPlugin.class.Group, group.space, group._id)
        dispatch("close")
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
    <div class="members-section mt-4">
      <div class="font-medium-14 mb-2">Members</div>
      <AccountArrayEditor
        label={groupPlugin.string.GroupMembers}
        value={members}
        onChange={handleMembersChange}
        kind="link"
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
  .font-medium-14 { font-weight: 500; font-size: 0.875rem; }
  .mb-2 { margin-bottom: 0.5rem; }
  .mt-4 { margin-top: 1rem; }
</style>