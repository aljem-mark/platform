<script lang="ts">
  import { onMount } from "svelte"
  import { getClient } from "@hcengineering/presentation"
  import { type Group } from "@hcengineering/group"
  import groupPlugin from "@hcengineering/group"
  import { showPopup, Header, Breadcrumb, Scroller, ModernButton, IconAdd } from "@hcengineering/ui"
  import CreateGroup from "./CreateGroup.svelte"

  let groups: Group[] = []
  let loading = true

  onMount(async () => {
    await loadGroups()
  })

  async function loadGroups (): Promise<void> {
    const client = getClient()
    try {
      groups = await client.findAll(groupPlugin.class.Group, {})
    } catch (e) {
      console.error("Failed to load groups", e)
    } finally {
      loading = false
    }
  }

  function handleCreate (): void {
    showPopup(CreateGroup, {}, "top", () => {
      loading = true
      void loadGroups()
    })
  }
</script>

<div class="hulyComponent">
  <Header adaptive={"disabled"}>
    <Breadcrumb icon={groupPlugin.icon.Group} label={groupPlugin.string.Groups} size={"large"} isCurrent />
    <svelte:fragment slot="actions">
      <ModernButton kind="primary" icon={IconAdd} label={groupPlugin.string.CreateGroup} size="small" on:click={handleCreate} />
    </svelte:fragment>
  </Header>
  <div class="hulyComponent-content__column content">
    {#if loading}
      <div class="w-full h-full flex-col-center justify-center">
        <div class="flex-col-center"><p class="p-2">Loading groups...</p></div>
      </div>
    {:else if groups.length === 0}
      <div class="flex-col-center mt-8">
        <p>No groups created yet.</p>
      </div>
    {:else}
      <Scroller align={"center"} padding={"var(--spacing-3)"} bottomPadding={"var(--spacing-3)"}>
        <div class="hulyComponent-content">
          {#each groups as group}
            <div class="flex-row-center p-2 flex-no-shrink">
              <div class="p-1 min-w-80">
                <span class="font-medium-14">{group.name}</span>
              </div>
              <div class="p-1 text-sm">
                ({group.members.length} member{group.members.length !== 1 ? "s" : ""})
              </div>
            </div>
          {/each}
        </div>
      </Scroller>
    {/if}
  </div>
</div>

<style lang="scss">
  .font-medium-14 {
    font-weight: 500;
    font-size: 0.875rem;
  }
  .text-sm {
    font-size: 0.875rem;
    color: var(--theme-caption-color);
  }
</style>