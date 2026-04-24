class SkillStore:
    def __init__(self, chroma_client):
        self.collections = {
            "knowledge": chroma_client.get_or_create_collection("skills_knowledge"),
            "execution": chroma_client.get_or_create_collection("skills_execution"),
            "behavior": chroma_client.get_or_create_collection("skills_behavior"),
        }

    def add(self, text, skill_type):
        self.collections[skill_type].add(
            documents=[text],
            ids=[str(hash(text))]
        )

    def query(self, skill_type, query, n=2):
        return self.collections[skill_type].query(
            query_texts=[query],
            n_results=n
        )["documents"]
