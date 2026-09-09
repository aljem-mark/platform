
<script lang="ts">
  import { createQuery, getClient } from "@hcengineering/presentation"
  import { type Group } from "@hcengineering/group"
  import groupPlugin from "@hcengineering/group"
  import { showPopup, Header, Breadcrumb, ModernButton, IconAdd, IconEdit } from "@hcengineering/ui"
  import { AccountArrayEditor } from "@hcengineering/contact-resources"
  import CreateGroup from "./CreateGroup.svelte"

  let groups: Group[] = []
  let loading = true

  const groupQuery = createQuery()

  groupQuery.query(groupPlugin.class.Group, {}, (res: Group[]) => {
    groups = res
    loading = false
  })

  function handleCreate (): void {
    showPopup(CreateGroup, {}, "top")
  }

  function handleEdit (group: Group): void {
    showPopup(CreateGroup, { group }, "top")
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
        <p class="p-2">Loading groups...</p>
      </div>
    {:else if groups.length === 0}
      <div class="flex-col-center mt-8">
        <p>No groups created yet.</p>
      </div>
    {:else}
      {#each groups as group}
        <div class="antiGrid-row">
          <div class="antiGrid-row__header">{group.name}</div>
          <AccountArrayEditor
            value={group.members}
            label={groupPlugin.string.GroupMembers}
            onChange={(newMembers) => {
              const client = getClient()
              void client.update(group, { members: newMembers })
            }}
            kind="regular"
            size="large"
          />
          <button class="edit-btn" on:click={() => handleEdit(group)} title="Edit group">
          <IconEdit size={"small"} />
        </button>
        </div>
      {/each}
    {/if}
  </div>
</div>

<style lang="scss">
  .antiGrid-row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.25rem 0;
  }
  .antiGrid-row__header {
    flex-shrink: 0;
    width: 12rem;
    font-size: 0.875rem;
    font-weight: 400;
    color: var(--theme-caption-color);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .edit-btn {
    display: inline-flex;
    align-items: center;
    background: none;
    border: none;
    cursor: pointer;
    padding: 0.25rem;
    color: var(--theme-caption-color);
    font-size: 0.875rem;
    &:hover { color: var(--theme-accent-color); }
  }
  .content {
    margin: 2rem 3.25rem;
    max-width: 50rem;
  }
</style>
