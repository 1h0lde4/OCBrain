class SkillEngine:
    def __init__(self, store):
        self.store = store

    def retrieve(self, query):
        return {
            "knowledge": self.store.query("knowledge", query),
            "execution": self.store.query("execution", query),
            "behavior": self.store.query("behavior", query),
        }
