// A minimal IDataSource for List + LazyForEach (design §6.3): the long inbox/archived lists
// virtualize their rows instead of building every one. reload() swaps the items and tells the
// list to re-read; the page drives it from the store's observed rows.
export class ListSource<T> implements IDataSource {
  private items: T[];
  private listeners: DataChangeListener[] = [];

  constructor(items: T[]) {
    this.items = items;
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  reload(items: T[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}
