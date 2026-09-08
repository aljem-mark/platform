<script lang="ts">
  import { createEventDispatcher } from "svelte"
  import core, { type AccountUuid } from "@hcengineering/core"
  import presentation, { getClient } from "@hcengineering/presentation"
  import { Modal, ModernEditbox } from "@hcengineering/ui"
  import groupPlugin from "@hcengineering/group"
  
  const dispatch = createEventDispatcher()
  const client = getClient()

  let name: string = ""
  let saving = false

  $: canSave = name.trim().length > 0 && !saving

  async function save (): Promise<void> {
    if (!canSave) return
    saving = true
    try {
      await client.createDoc(
        groupPlugin.class.Group,
        core.space.Workspace,
        {
          name: name.trim(),
          description: "",
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

<Modal
  label={groupPlugin.string.CreateGroup}
  type={"type-popup"}
  okLabel={presentation.string.Save}
  okAction={save}
  onCancel={() => dispatch("close")}
  bind:canSave
>
  <div class="flex-col">
    <ModernEditbox
      bind:value={name}
      label={groupPlugin.string.GroupNamePlaceholder}
      kind={"ghost"}
      size={"large"}
      width={"100%"}
    />
  </div>
</Modal>
