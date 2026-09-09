<script lang="ts">
  import { createQuery, getClient } from "@hcengineering/presentation"
  import { type Group } from "@hcengineering/group"
  import groupPlugin from "@hcengineering/group"
  import { showPopup, Header, Breadcrumb, Scroller, ModernButton, IconAdd, ButtonIcon, IconDelete } from "@hcengineering/ui"
  import CreateGroup from "./CreateGroup.svelte"
  import { AccountArrayEditor } from "@hcengineering/contact-resources"

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
                {#if group.description}
                  <span class="text-sm">{group.description}</span>
                {/if}
              </div>
              <div class="members-pill">
                <AccountArrayEditor
                  label={groupPlugin.string.GroupMembers}
                  value={group.members}
                  onChange={(newMembers) => {
                    const client = getClient()
                    void client.update(group, { members: newMembers })
                  }}
                  kind="link"
                  size="large"
                  allowGuests={true}
                />
              </div>
              <button class="edit-btn" on:click={() => handleEdit(group)}>
                <span class="icon">{'✎'}</span>
              </button>
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
  .members-pill {
    min-width: 10rem;
    margin: 0 0.5rem;
  }
  .edit-btn {
    background: none;
    border: none;
    cursor: pointer;
    padding: 0.25rem 0.5rem;
    color: var(--theme-caption-color);
    &:hover { color: var(--theme-accent-color); }
    .icon { font-size: 1rem; }
  }
</style>