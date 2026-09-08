<script lang="ts">
  import { createEventDispatcher } from "svelte"
  import core, { type AccountUuid } from "@hcengineering/core"
  import { getClient, Card } from "@hcengineering/presentation"
  import { EditBox } from "@hcengineering/ui"
  import groupPlugin from "@hcengineering/group"

  const dispatch = createEventDispatcher()
  const client = getClient()

  let name: string = ""
  let description: string = ""
  let saving = false

  $: canSave = name.trim().length > 0 && !saving

  async function createGroup (): Promise<void> {
    if (!canSave) return
    saving = true
    try {
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
    } catch (e) {
      console.error("Failed to create group", e)
    } finally {
      saving = false
      dispatch("close")
    }
  }
</script>

<Card
  label={groupPlugin.string.CreateGroup}
  {canSave}
  okAction={createGroup}
  on:close={() => dispatch("close")}
  on:changeContent
>
  <div class="flex-col flex-gap-2">
    <EditBox
      bind:value={name}
      placeholder={groupPlugin.string.GroupNamePlaceholder}
      kind="large-style"
      focusIndex={1}
      autoFocus
      fullSize
    />
    <EditBox
      bind:value={description}
      placeholder={groupPlugin.string.GroupDescriptionPlaceholder}
      kind="large-style"
      focusIndex={2}
      fullSize
    />
  </div>
</Card>